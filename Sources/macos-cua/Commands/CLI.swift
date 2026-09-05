import AppKit
import Foundation

enum CLI {
    static let usage = """
    Usage:
      macos-cua [--json] [--relative] <command> [args...]

    Core commands:
      doctor
      onboard [--wait|--no-wait] [--timeout <seconds>] [--no-request] [--no-open]
      state
      cursor-position
      screen-size
      open-url <url>
      screenshot [--screen] [--region x y w h] <path.png> [window|screen]
      move <x> <y> [--screen] [--fast|--precise]
      mousedown <x> <y> [left|right|middle] [--screen] [--fast|--precise]
      mouseup [left|right|middle]
      click <x> <y> [left|right|middle] [--screen] [--fast|--precise] [--post-crop <path.png>]
      scroll <dx> <dy>
      keypress <key[+key...]>
      type [--fast] <text>
      wait <ms>
      clipboard get|set|copy|paste

    Basic app/window management:
      app list|activate
      window list|activate

    Notes:
      Coordinates default to the frontmost-window coordinate space.
      Use --screen to interpret coordinates in main-screen space.
      Window bounds remain reported in screen-global coordinates.
      Use screenshot --region as the fallback for dense pages and small targets.
      When a click looks off, use --post-crop to capture a local debug crop.
      Do not assume the crop center is the click point. Use postCropClickPoint
        as the actual click location inside the crop, then map corrected crop
        coordinates back through postCropBounds/origin.
      Pointer movement defaults to the fast humanized profile.
      Prefer absolute coordinates first.
      --relative is a fallback mode: it interprets all action coordinates as
        integers in [0, 1000] relative to the active coordinate space.
    """

    static func run(arguments: [String]) throws {
        var args = arguments
        var json = false
        var relative = false
        var parsingGlobalFlags = true
        while parsingGlobalFlags, let first = args.first {
            switch first {
            case "--json":
                json = true
                args.removeFirst()
            case "--relative":
                relative = true
                args.removeFirst()
            default:
                parsingGlobalFlags = false
            }
        }
        guard let command = args.first else {
            print(usage)
            return
        }
        if ["-h", "--help", "help"].contains(command) {
            print(usage)
            return
        }

        let output = CLIOutput(json: json)
        try Recorder.executeInvocation(arguments: arguments, command: command, output: output) {
            switch command {
            case "onboard", "onboarding":
                try onboard(args: Array(args.dropFirst()), output: output)
            case "doctor":
                try doctor(output: output)
            case "state":
                try state(output: output, relative: relative)
            case "cursor-position":
                try cursorPosition(output: output)
            case "screen-size":
                try screenSize(output: output)
            case "open-url":
                try openURL(args: Array(args.dropFirst()), output: output)
            case "screenshot":
                try screenshot(args: Array(args.dropFirst()), output: output, relative: relative)
            case "move":
                try move(args: Array(args.dropFirst()), output: output, relative: relative)
            case "mousedown":
                try mouseDown(args: Array(args.dropFirst()), output: output, relative: relative)
            case "mouseup":
                try mouseUp(args: Array(args.dropFirst()), output: output)
            case "click":
                try click(args: Array(args.dropFirst()), output: output, relative: relative)
            case "scroll":
                try scroll(args: Array(args.dropFirst()), output: output)
            case "keypress":
                try keypress(args: Array(args.dropFirst()), output: output)
            case "type":
                try typeText(args: Array(args.dropFirst()), output: output)
            case "wait":
                try wait(args: Array(args.dropFirst()), output: output)
            case "clipboard":
                try clipboard(args: Array(args.dropFirst()), output: output)
            case "app":
                try app(args: Array(args.dropFirst()), output: output)
            case "window":
                try window(args: Array(args.dropFirst()), output: output)
            default:
                throw CUAError(message: "unsupported command: \(command)")
            }
        }
    }

    static func onboard(args: [String], output: CLIOutput) throws {
        var waitForReady = PermissionSupport.isInteractiveSession()
        var timeoutSeconds = waitForReady ? 120 : 0
        var requestPrompt = true
        var openSettings = true
        var index = 0

        while index < args.count {
            switch args[index] {
            case "--wait":
                waitForReady = true
                if timeoutSeconds == 0 {
                    timeoutSeconds = 120
                }
                index += 1
            case "--no-wait":
                waitForReady = false
                timeoutSeconds = 0
                index += 1
            case "--timeout":
                guard index + 1 < args.count else {
                    throw CUAError(message: "usage: macos-cua onboard [--wait|--no-wait] [--timeout <seconds>] [--no-request] [--no-open]")
                }
                timeoutSeconds = try parseInt(args[index + 1], name: "timeout")
                if timeoutSeconds < 0 {
                    throw CUAError(message: "timeout must be >= 0")
                }
                waitForReady = timeoutSeconds > 0
                index += 2
            case "--no-request":
                requestPrompt = false
                index += 1
            case "--no-open":
                openSettings = false
                index += 1
            default:
                throw CUAError(message: "usage: macos-cua onboard [--wait|--no-wait] [--timeout <seconds>] [--no-request] [--no-open]")
            }
        }

        let progress: ((String) -> Void)? = output.json ? nil : { line in
            print(line)
        }
        let shouldLogProgress = PermissionSupport.isInteractiveSession() && (waitForReady || requestPrompt || openSettings)
        let result = PermissionSupport.onboarding(
            requestPrompts: requestPrompt,
            openSettingsPane: openSettings,
            waitForReady: waitForReady,
            timeoutSeconds: timeoutSeconds,
            log: shouldLogProgress ? progress : nil
        )
        try output.emit(result.payload, lines: result.lines)
    }

    static func doctor(output: CLIOutput) throws {
        let accessibility = WindowSupport.isAccessibilityTrusted()
        let screenRecording = ScreenshotSupport.screenCaptureAccess()
        let frontmostApp = AppSupport.frontmostApplication().map(AppSupport.record(for:))?.json
        let frontmostWindow = WindowSupport.frontmostWindow()?.json
        let actionSpace = try InputSupport.actionSpace()

        var screenshotCheck: [String: Any] = [
            "ok": false,
        ]
        if screenRecording {
            let tempPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macos-cua-doctor-\(UUID().uuidString).png")
            do {
                _ = try ScreenshotSupport.capture(
                    target: .screen,
                    path: tempPath.path,
                    coordinateSpace: .screen,
                    coordinateFallback: false,
                    reportedBounds: ScreenshotSupport.screenBounds()
                )
                screenshotCheck = ["ok": true, "path": tempPath.path]
                try? FileManager.default.removeItem(at: tempPath)
            } catch {
                screenshotCheck = ["ok": false, "error": error.localizedDescription]
            }
        }

        let payload: [String: Any] = [
            "accessibility": accessibility,
            "screenRecording": screenRecording,
            "syntheticInputReady": accessibility,
            "screenshotReady": screenshotCheck,
            "allReady": accessibility && screenRecording,
            "onboardCommand": "macos-cua onboard",
            "frontmostApp": frontmostApp as Any,
            "frontmostWindow": frontmostWindow as Any,
            "actionSpace": actionSpace,
        ]
        var lines = [
            "Accessibility: \(accessibility ? "ready" : "missing")",
            "Screen Recording: \(screenRecording ? "ready" : "missing")",
            "Synthetic input: \(accessibility ? "ready" : "missing")",
            "Screenshot check: \((screenshotCheck["ok"] as? Bool) == true ? "ok" : "failed")",
            "Frontmost app: \((frontmostApp?["name"] as? String) ?? "n/a")",
            "Frontmost window: \((frontmostWindow?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "<untitled>")",
        ]
        if !accessibility || !screenRecording {
            lines.append("Next: run `macos-cua onboard` to request missing permissions.")
        }
        try output.emit(
            payload,
            lines: lines
        )
    }

    static func state(output: CLIOutput, relative: Bool) throws {
        let pointerScreen = InputSupport.currentPointer()
        let coordinateContext = CoordinateSupport.context(explicitScreen: false, relative: relative)
        let pointerWindow = coordinateContext.pointerWindowPoint(fromScreenPoint: pointerScreen)
        let modifiers = InputSupport.currentModifierNames()
        let mouseButtons = InputSupport.currentMouseButtons()
        let frontmostApp = AppSupport.frontmostApplication().map(AppSupport.record(for:))?.json
        let frontmostWindow = WindowSupport.frontmostWindow()?.json
        let blockingModalState = WindowSupport.currentBlockingModalState()
        let pointerWindowLine = pointerWindow.map {
            "\(Int($0.x.rounded())),\(Int($0.y.rounded()))"
        } ?? "n/a"
        var releaseHints: [String] = []
        releaseHints.append(contentsOf: modifiers.map { "release key \($0)" })
        releaseHints.append(contentsOf: mouseButtons.map { "release mouse \($0)" })

        let held: [String: Any] = [
                "modifiers": modifiers,
                "mouseButtons": mouseButtons,
        ]
        let payload = coordinateContext.statePayload(
            pointerScreen: pointerScreen,
            actionSpace: try InputSupport.actionSpace(),
            held: held,
            releaseHints: releaseHints,
            frontmostApp: frontmostApp,
            frontmostWindow: frontmostWindow
        )
        var enrichedPayload = payload
        applyBlockingModalState(blockingModalState, to: &enrichedPayload)
        var lines = [
            "Default coordinates: \(coordinateContext.summary)",
            "Pointer (screen): \(Int(pointerScreen.x.rounded())),\(Int(pointerScreen.y.rounded()))",
            "Pointer (window): \(pointerWindowLine)",
            "Held modifiers: \(modifiers.isEmpty ? "none" : modifiers.joined(separator: ", "))",
            "Held mouse buttons: \(mouseButtons.isEmpty ? "none" : mouseButtons.joined(separator: ", "))",
            "Frontmost app: \((frontmostApp?["name"] as? String) ?? "n/a")",
            "Frontmost window: \((frontmostWindow?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "<untitled>")",
        ]
        if let line = blockingModalState.line {
            lines.append(line)
        }
        try output.emit(
            enrichedPayload,
            lines: lines
        )
    }

    static func cursorPosition(output: CLIOutput) throws {
        let pointerScreen = InputSupport.currentPointer()
        let context = CoordinateSupport.context(explicitScreen: false, relative: false)
        try output.emit([
            "pointerScreen": CoordinateSupport.pointJSON(pointerScreen),
            "pointerWindow": context.pointerWindowPoint(fromScreenPoint: pointerScreen)
                .map(CoordinateSupport.pointJSON) as Any,
            "defaultCoordinateSpace": context.coordinateSpaceName,
        ])
    }

    static func screenSize(output: CLIOutput) throws {
        let actionSpace = try InputSupport.actionSpace()
        try output.emit(["actionSpace": actionSpace])
    }

    static func openURL(args: [String], output: CLIOutput) throws {
        guard args.count == 1 else {
            throw CUAError(message: "usage: macos-cua open-url <url>")
        }
        guard let url = URL(string: args[0]),
              let scheme = url.scheme,
              !scheme.isEmpty else {
            throw CUAError(message: "invalid URL: \(args[0])")
        }
        let ok = NSWorkspace.shared.open(url)
        let payload: [String: Any] = [
            "ok": ok,
            "url": url.absoluteString,
            "recommendedTool": "bb-browser",
            "note": "Prefer bb-browser for browser tasks.",
        ]
        try output.emit(
            payload,
            lines: [
                "Opened URL: \(url.absoluteString)",
                "For browser tasks, prefer bb-browser.",
            ]
        )
    }

    static func screenshot(args: [String], output: CLIOutput, relative: Bool) throws {
        let options = try parseScreenshotOptions(args)
        guard (1...2).contains(options.remaining.count) else {
            throw CUAError(
                message: "usage: macos-cua screenshot [--screen] [--region x y w h] <path.png> [window|screen]"
            )
        }
        let requestedTarget = try options.remaining.dropFirst().first.map(ScreenshotSupport.target(named:))
        if options.region != nil, requestedTarget != nil {
            throw CUAError(message: "--region cannot be combined with a positional screenshot target")
        }
        let target: ScreenshotTarget
        if let region = options.region {
            let screenContext = CoordinateSupport.context(explicitScreen: true, relative: relative)
            target = .region(try screenContext.inputRect(region).screen)
        } else if let requestedTarget {
            target = requestedTarget
        } else {
            target = options.explicitScreen ? .screen : .frontmostWindow
        }
        let explicitScreen = options.explicitScreen || requestedTarget == .screen || options.region != nil
        let coordinateContext = CoordinateSupport.context(explicitScreen: explicitScreen, relative: relative)
        let reportedBounds = coordinateContext.screenshotReportedBounds(for: target)
        var payload = try ScreenshotSupport.capture(
            target: target,
            path: options.remaining[0],
            coordinateSpace: coordinateContext.coordinateSpace,
            coordinateFallback: coordinateContext.coordinateFallback,
            reportedBounds: reportedBounds
        )
        coordinateContext.applyMetadata(to: &payload)
        let image = payload["image"] as? [String: Any]
        payload["width"] = image?["width"]
        payload["height"] = image?["height"]
        let bounds = payload["bounds"] as? [String: Any]
        let human = "captured \(payload["target"] as? String ?? "screenshot") to \(options.remaining[0]) (\(image?["width"] ?? "?")x\(image?["height"] ?? "?"), \(coordinateContext.summary), bounds \(bounds?["x"] ?? "?"),\(bounds?["y"] ?? "?") \(bounds?["width"] ?? "?")x\(bounds?["height"] ?? "?"))"
        try output.emit(payload, human: human)
    }

    static func move(args: [String], output: CLIOutput, relative: Bool) throws {
        let (rest, profile, explicitScreen) = try parsePointerProfile(args, usage: "usage: macos-cua move <x> <y> [--screen] [--fast|--precise]")
        guard rest.count == 2 else {
            throw CUAError(message: "usage: macos-cua move <x> <y> [--screen] [--fast|--precise]")
        }
        let x = try parseInt(rest[0], name: "x")
        let y = try parseInt(rest[1], name: "y")
        let coordinateContext = CoordinateSupport.context(explicitScreen: explicitScreen, relative: relative)
        let actionPoint = try coordinateContext.inputPoint(x: x, y: y)
        _ = try InputSupport.performMotion(to: actionPoint.screen, profile: profile, kind: .move)
        var payload = coordinateContext.actionPayload(x: x, y: y, screenPoint: actionPoint.screen)
        payload["profile"] = profile.rawValue
        if let feedback = AccessibilitySupport.feedback(for: actionPoint.screen, context: coordinateContext) {
            for (key, value) in feedback {
                payload[key] = value
            }
        }
        var human = "moved pointer to \(x),\(y) [\(relative ? "relative, " : "")\(coordinateContext.summary), screen \(Int(actionPoint.screen.x.rounded())),\(Int(actionPoint.screen.y.rounded()))] [\(profile.rawValue)]"
        if let feedback = payload["feedback"] as? String {
            human += " | \(feedback)"
        } else if let feedbackLines = payload["feedback"] as? [String], !feedbackLines.isEmpty {
            human += " | " + feedbackLines.joined(separator: " -> ")
        }
        try output.emit(payload, human: human)
    }

    static func mouseDown(args: [String], output: CLIOutput, relative: Bool) throws {
        let usage = "usage: macos-cua mousedown <x> <y> [left|right|middle] [--screen] [--fast|--precise]"
        let (rest, profile, explicitScreen) = try parsePointerProfile(args, usage: usage)
        guard (2...3).contains(rest.count) else {
            throw CUAError(message: usage)
        }
        let x = try parseInt(rest[0], name: "x")
        let y = try parseInt(rest[1], name: "y")
        let button = try InputSupport.mouseButton(named: rest.count == 3 ? rest[2] : "left")
        let coordinateContext = CoordinateSupport.context(explicitScreen: explicitScreen, relative: relative)
        let actionPoint = try coordinateContext.inputPoint(x: x, y: y)
        _ = try InputSupport.performMotion(to: actionPoint.screen, profile: profile, kind: .move)
        try InputSupport.mouseDown(at: actionPoint.screen, button: button)
        var payload = coordinateContext.actionPayload(x: x, y: y, screenPoint: actionPoint.screen)
        payload["button"] = button.rawValue
        payload["profile"] = profile.rawValue
        payload["mouseAction"] = "mousedown"
        let human = "mousedown \(button.rawValue) at \(x),\(y) [\(relative ? "relative, " : "")\(coordinateContext.summary), screen \(Int(actionPoint.screen.x.rounded())),\(Int(actionPoint.screen.y.rounded()))] [\(profile.rawValue)]"
        try output.emit(payload, human: human)
    }

    static func mouseUp(args: [String], output: CLIOutput) throws {
        guard args.count <= 1 else {
            throw CUAError(message: "usage: macos-cua mouseup [left|right|middle]")
        }
        let button = try InputSupport.mouseButton(named: args.first ?? "left")
        let point = InputSupport.currentPointer()
        try InputSupport.mouseUp(at: point, button: button)
        let payload: [String: Any] = [
            "button": button.rawValue,
            "mouseAction": "mouseup",
            "screenPoint": CoordinateSupport.pointJSON(point),
        ]
        let human = "mouseup \(button.rawValue) at current pointer [screen \(Int(point.x.rounded())),\(Int(point.y.rounded()))]"
        try output.emit(payload, human: human)
    }

    static func click(args: [String], output: CLIOutput, relative: Bool) throws {
        let usage = "usage: macos-cua click <x> <y> [left|right|middle] [--screen] [--fast|--precise] [--post-crop <path.png>]"
        let (rest, profile, explicitScreen, postCropPath) = try parseClickOptions(args, usage: usage)
        guard (2...3).contains(rest.count) else {
            throw CUAError(message: usage)
        }
        let x = try parseInt(rest[0], name: "x")
        let y = try parseInt(rest[1], name: "y")
        let button = try InputSupport.mouseButton(named: rest.count == 3 ? rest[2] : "left")
        let coordinateContext = CoordinateSupport.context(explicitScreen: explicitScreen, relative: relative)
        let actionPoint = try coordinateContext.inputPoint(x: x, y: y)
        try InputSupport.click(point: actionPoint.screen, button: button, count: 1, profile: profile)
        let payload: [String: Any] = [
            "accepted": true,
            "pointerScreen": CoordinateSupport.pointJSON(actionPoint.screen),
            "inputUnits": NSNull(),
        ]
        if let postCropPath {
            var debugPayload = payload
            let cropBounds = coordinateContext.cropBounds()
            if let bounds = cropBounds,
               let crop = ScreenshotSupport.cropRect(centeredAt: actionPoint.screen, within: bounds),
               let cropPayload = try? ScreenshotSupport.capture(
                    target: .region(crop),
                    path: postCropPath,
                    coordinateSpace: .screen,
                    coordinateFallback: false,
                    reportedBounds: crop
               ) {
                let cropPoint = CGPoint(x: actionPoint.screen.x - crop.origin.x, y: actionPoint.screen.y - crop.origin.y)
                try? ScreenshotSupport.annotatePostCrop(
                    at: URL(fileURLWithPath: postCropPath),
                    markerPoint: cropPoint
                )
                debugPayload["postCropPath"] = cropPayload["path"]
                debugPayload["postCropBounds"] = coordinateContext.outputRectJSON(fromScreenRect: crop)
                debugPayload["postCropOrigin"] = coordinateContext.outputPointJSON(fromScreenPoint: crop.origin)
                debugPayload["postCropClickPoint"] = CoordinateSupport.pointJSON(cropPoint)
            }
            try output.emit(debugPayload, human: "clicked \(button.rawValue) at \(x),\(y)")
            return
        }
        try output.emit(payload, human: "clicked \(button.rawValue) at \(x),\(y)")
    }

    static func scroll(args: [String], output: CLIOutput) throws {
        guard args.count == 2 else {
            throw CUAError(message: "usage: macos-cua scroll <dx> <dy>")
        }
        let dx = try parseInt(args[0], name: "dx")
        let dy = try parseInt(args[1], name: "dy")
        try InputSupport.scroll(dx: dx, dy: dy)
        try output.emit(["dx": dx, "dy": dy], human: "scrolled \(dx),\(dy)")
    }

    static func keypress(args: [String], output: CLIOutput) throws {
        guard args.count == 1 else {
            throw CUAError(message: "usage: macos-cua keypress <key[+key...]>")
        }
        try InputSupport.keypress(args[0])
        try output.emit(["keys": args[0]], human: "sent keypress: \(args[0])")
    }

    static func typeText(args: [String], output: CLIOutput) throws {
        guard !args.isEmpty else {
            throw CUAError(message: "usage: macos-cua type [--fast] <text>")
        }
        var rest = args
        var fast = false
        if rest.first == "--fast" {
            fast = true
            rest.removeFirst()
        }
        guard rest.count == 1 else {
            throw CUAError(message: "usage: macos-cua type [--fast] <text>")
        }
        try InputSupport.typeText(rest[0], fast: fast)
        try output.emit(
            [
                "accepted": true,
                "pointerScreen": NSNull(),
                "inputUnits": rest[0].utf16.count,
            ],
            human: "typed \(rest[0].count) characters"
        )
    }

    static func wait(args: [String], output: CLIOutput) throws {
        guard args.count == 1 else {
            throw CUAError(message: "usage: macos-cua wait <ms>")
        }
        let ms = try parseInt(args[0], name: "ms")
        usleep(useconds_t(ms * 1_000))
        try output.emit(["ms": ms], human: "waited \(ms)ms")
    }

    static func clipboard(args: [String], output: CLIOutput) throws {
        guard let subcommand = args.first else {
            throw CUAError(message: "usage: macos-cua clipboard get|set|copy|paste")
        }
        switch subcommand {
        case "get":
            let text = try ClipboardSupport.getText()
            try output.emit(["text": text], human: text)
        case "set":
            guard args.count == 2 else {
                throw CUAError(message: "usage: macos-cua clipboard set <text>")
            }
            try ClipboardSupport.setText(args[1])
            try output.emit(["ok": true, "length": args[1].count], human: "clipboard updated")
        case "copy":
            try ClipboardSupport.copySelection()
            try output.emit(["ok": true], human: "sent copy shortcut")
        case "paste":
            try ClipboardSupport.pasteClipboard()
            try output.emit(["ok": true], human: "sent paste shortcut")
        default:
            throw CUAError(message: "unsupported clipboard command: \(subcommand)")
        }
    }

    static func app(args: [String], output: CLIOutput) throws {
        guard let subcommand = args.first else {
            throw CUAError(message: "usage: macos-cua app list|activate")
        }
        switch subcommand {
        case "list":
            let records = AppSupport.runningUserApplications().map(AppSupport.record(for:))
            try output.emit(
                records.map(\.json),
                lines: records.isEmpty ? ["No running user apps found."] : records.map(\.line)
            )
        case "activate":
            guard args.count >= 2 else {
                throw CUAError(message: "usage: macos-cua app activate <name-or-bundle-id>")
            }
            let query = args.dropFirst().joined(separator: " ")
            let payload = try AppSupport.activate(query: query)
            let record = (payload["app"] as? [String: Any])?["name"] as? String ?? query
            try output.emit(payload, human: "activated app: \(record)")
        default:
            throw CUAError(message: "unsupported app command: \(subcommand)")
        }
    }

    static func window(args: [String], output: CLIOutput) throws {
        guard let subcommand = args.first else {
            throw CUAError(message: "usage: macos-cua window list|activate")
        }
        switch subcommand {
        case "list":
            let windows = WindowSupport.listWindows()
            let duplicateTitleHintNeeded = !WindowSupport.duplicateTitleWindows(in: windows).isEmpty
            var lines = windows.isEmpty ? ["No interactive windows found."] : windows.map(\.line)
            if duplicateTitleHintNeeded {
                lines.append(WindowSupport.duplicateTitleHint)
            }
            try output.emit(
                windows.map(\.json),
                lines: lines
            )
        case "activate":
            guard args.count == 2 else {
                throw CUAError(message: "usage: macos-cua window activate <id>")
            }
            let id = try parseInt(args[1], name: "window id")
            let payload = try WindowSupport.activateWindow(id: id)
            let human = (payload["hint"] as? String).map { "activated window \(id)\n\($0)" } ?? "activated window \(id)"
            try output.emit(payload, human: human)
        default:
            throw CUAError(message: "unsupported window command: \(subcommand)")
        }
    }

    static func parsePointerProfile(_ args: [String], usage: String) throws -> ([String], PointerMotionProfile, Bool) {
        var rest: [String] = []
        var selected: PointerMotionProfile = .fast
        var explicit = false
        var explicitScreen = false

        for arg in args {
            switch arg {
            case "--fast":
                if explicit && selected != .fast {
                    throw CUAError(message: usage)
                }
                selected = .fast
                explicit = true
            case "--precise":
                if explicit && selected != .precise {
                    throw CUAError(message: usage)
                }
                selected = .precise
                explicit = true
            case "--screen":
                if explicitScreen {
                    throw CUAError(message: usage)
                }
                explicitScreen = true
            case "--duration-ms":
                throw CUAError(message: "move --duration-ms has been removed; use --fast or --precise")
            default:
                rest.append(arg)
            }
        }
        return (rest, selected, explicitScreen)
    }

    static func parseClickOptions(_ args: [String], usage: String) throws -> ([String], PointerMotionProfile, Bool, String?) {
        var rest: [String] = []
        var selected: PointerMotionProfile = .fast
        var explicit = false
        var explicitScreen = false
        var postCropPath: String?
        var index = 0

        while index < args.count {
            switch args[index] {
            case "--fast":
                if explicit && selected != .fast { throw CUAError(message: usage) }
                selected = .fast
                explicit = true
                index += 1
            case "--precise":
                if explicit && selected != .precise { throw CUAError(message: usage) }
                selected = .precise
                explicit = true
                index += 1
            case "--screen":
                if explicitScreen { throw CUAError(message: usage) }
                explicitScreen = true
                index += 1
            case "--post-crop":
                guard postCropPath == nil, index + 1 < args.count else {
                    throw CUAError(message: usage)
                }
                postCropPath = args[index + 1]
                index += 2
            default:
                rest.append(args[index])
                index += 1
            }
        }

        return (rest, selected, explicitScreen, postCropPath)
    }

    static func parseScreenshotOptions(_ args: [String]) throws
        -> (remaining: [String], explicitScreen: Bool, region: CGRect?)
    {
        var remaining: [String] = []
        var explicitScreen = false
        var region: CGRect?
        var index = 0

        while index < args.count {
            switch args[index] {
            case "--screen":
                guard !explicitScreen else {
                    throw CUAError(message: "duplicate --screen option")
                }
                explicitScreen = true
                index += 1
            case "--region":
                guard region == nil, index + 4 < args.count else {
                    throw CUAError(message: "invalid --region option")
                }
                let x = try parseInt(args[index + 1], name: "x")
                let y = try parseInt(args[index + 2], name: "y")
                let width = try parseInt(args[index + 3], name: "width")
                let height = try parseInt(args[index + 4], name: "height")
                region = CGRect(x: x, y: y, width: width, height: height)
                index += 5
            default:
                remaining.append(args[index])
                index += 1
            }
        }
        return (remaining, explicitScreen, region)
    }

    static func applyBlockingModalState(_ blockingModalState: WindowSupport.BlockingModalState, to payload: inout [String: Any]) {
        for (key, value) in blockingModalState.payload {
            payload[key] = value
        }
    }
}
