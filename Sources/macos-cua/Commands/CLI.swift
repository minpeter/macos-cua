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
      type [--fast] [--] <one text>
      wait <ms>
      clipboard get|set|copy|paste

    Basic app/window management:
      app list | app activate <one name-or-bundle-id>
      window list | window activate <id>

    Notes:
      Coordinates use macOS logical points, defaulting to the frontmost usable
        window, otherwise the primary screen. Bounds and pointerScreen are global.
      Use --screen to select primary-screen coordinates. --region is window-local
        by default; --relative scales its origin and size across the full extent.
      Screenshot PNG pixels are normalized to logical points, not Retina backing
        pixels. Region captures show the composited visible desktop; window
        captures use native window capture when an exact window ID is available.
      Global --json and --relative must precede the command; no repeated flags.
      Use type -- --fast to type the literal text --fast. Maximum: 8192 UTF-16 units.
      wait accepts 0..20000 milliseconds; all action integers are signed 32-bit.
      doctor checks Accessibility and Screen Recording for this execution context.
      onboard requests macOS permissions; approve them in System Settings.
      No Windows broker or QA task setup is required on macOS.
      Window bounds remain reported in screen-global coordinates.
      Use screenshot --region as the fallback for dense pages and small targets.
      When a click looks off, use --post-crop to capture a local debug crop.
      Do not assume the crop center is the click point. Use postCropClickPoint
        as the actual click location inside the crop, then map corrected crop
        coordinates back through postCropBounds/origin.
      Pointer movement defaults to the fast humanized profile.
      Prefer absolute coordinates first.
      --relative is supported only by state, screenshot, move, mousedown, click.
        It interprets coordinates as integers in [0, 1000] in the selected space.
    """

    static func run(arguments: [String]) throws {
        let invocation = try validateInvocation(arguments)
        let args = [invocation.command] + invocation.args
        let command = invocation.command
        let json = invocation.json
        let relative = invocation.relative
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

    struct Invocation {
        let command: String
        let args: [String]
        let json: Bool
        let relative: Bool
    }

    static func requestsJSON(_ arguments: [String]) -> Bool {
        arguments.prefix(while: { $0.hasPrefix("--") }).contains("--json")
    }

    static func validateInvocation(_ arguments: [String]) throws -> Invocation {
        var index = 0
        var globals: Set<String> = []
        while index < arguments.count, ["--json", "--relative"].contains(arguments[index]) {
            guard globals.insert(arguments[index]).inserted else {
                throw CUAError(message: "duplicate \(arguments[index]) option", code: "invalid_arguments")
            }
            index += 1
        }
        let command = index < arguments.count ? arguments[index] : "help"
        let args = Array(arguments.dropFirst(min(index + 1, arguments.count)))
        let relative = globals.contains("--relative")
        do {
            try validateCommand(command, args: args, relative: relative)
        } catch {
            throw CUAError(message: error.localizedDescription, code: "invalid_arguments")
        }
        return Invocation(command: command, args: args, json: globals.contains("--json"), relative: relative)
    }

    static func validateCommand(_ command: String, args: [String], relative: Bool) throws {
        guard !relative || ["state", "screenshot", "move", "mousedown", "click"].contains(command) else {
            throw CUAError(message: "--relative is not supported for \(command)")
        }
        func count(_ allowed: ClosedRange<Int>) throws {
            guard allowed.contains(args.count) else {
                throw CUAError(message: "invalid arguments for \(command); see macos-cua --help")
            }
        }
        switch command {
        case "help", "--help", "-h", "doctor", "state", "cursor-position", "screen-size":
            try count(0...0)
        case "onboard", "onboarding":
            var seen: Set<String> = []
            var index = 0
            var timeout: Int?
            while index < args.count {
                let flag = args[index]
                guard ["--wait", "--no-wait", "--timeout", "--no-request", "--no-open"].contains(flag),
                      seen.insert(flag).inserted else {
                    throw CUAError(message: "unknown or repeated onboard option: \(flag)")
                }
                if flag == "--timeout" {
                    guard index + 1 < args.count else { throw CUAError(message: "--timeout requires seconds") }
                    let seconds = try parseInt(args[index + 1], name: "timeout")
                    guard seconds >= 0 else { throw CUAError(message: "timeout must be >= 0") }
                    timeout = seconds
                    index += 1
                }
                index += 1
            }
            guard !(seen.contains("--wait") && seen.contains("--no-wait")),
                  !(seen.contains("--no-wait") && (timeout ?? 0) > 0),
                  !(seen.contains("--wait") && timeout == 0) else {
                throw CUAError(message: "conflicting onboard wait options")
            }
        case "open-url":
            try count(1...1)
            guard let url = URL(string: args[0]), let scheme = url.scheme, !scheme.isEmpty else {
                throw CUAError(message: "invalid URL: \(args[0])")
            }
        case "screenshot":
            let options = try parseScreenshotOptions(args)
            if relative, let region = options.region { try CoordinateSupport.validateRelativeRect(region) }
        case "move", "mousedown", "click":
            let rest: [String]
            if command == "click" {
                rest = try parseClickOptions(args, usage: "invalid click options").0
            } else {
                rest = try parsePointerProfile(args, usage: "invalid \(command) options").0
            }
            guard (command == "move" ? 2...2 : 2...3).contains(rest.count) else {
                throw CUAError(message: "invalid arguments for \(command)")
            }
            let x = try parseInt(rest[0], name: "x")
            let y = try parseInt(rest[1], name: "y")
            if relative { try CoordinateSupport.validateRelativePoint(CGPoint(x: x, y: y)) }
            if rest.count == 3 { _ = try InputSupport.mouseButton(named: rest[2]) }
        case "mouseup":
            try count(0...1)
            _ = try InputSupport.mouseButton(named: args.first ?? "left")
        case "scroll":
            try count(2...2)
            _ = try parseInt(args[0], name: "dx")
            _ = try parseInt(args[1], name: "dy")
        case "keypress":
            try count(1...1)
            try validateKeypress(args[0])
        case "type":
            _ = try parseTypeOptions(args)
        case "wait":
            _ = try parseWait(args)
        case "clipboard", "app", "window":
            guard let subcommand = args.first else { throw CUAError(message: "missing \(command) subcommand") }
            switch (command, subcommand) {
            case ("clipboard", "get"), ("clipboard", "copy"), ("clipboard", "paste"), ("app", "list"), ("window", "list"):
                try count(1...1)
            case ("clipboard", "set"):
                try count(2...2)
            case ("app", "activate"):
                try count(2...2)
                guard !args[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !args[1].hasPrefix("-") else { throw CUAError(message: "invalid app query") }
            case ("window", "activate"):
                try count(2...2)
                _ = try parseWindowID(args[1])
            default:
                throw CUAError(message: "unsupported \(command) command: \(subcommand)")
            }
        default:
            throw CUAError(message: "unsupported command: \(command)")
        }
    }

    static func validateKeypress(_ combo: String) throws {
        var seenCodes: Set<CGKeyCode> = []
        var nonmodifiers = 0
        for component in combo.split(separator: "+", omittingEmptySubsequences: false) {
            let token = component.lowercased()
            let code = try InputSupport.keycode(for: token)
            guard seenCodes.insert(code).inserted else { throw CUAError(message: "repeated key: \(token)") }
            if !InputSupport.modifierMapping.contains(where: { $0.0 == token }) { nonmodifiers += 1 }
        }
        guard !seenCodes.isEmpty, nonmodifiers <= 1 else { throw CUAError(message: "keypress requires modifiers and at most one nonmodifier key") }
    }

    static func parseTypeOptions(_ args: [String]) throws -> (text: String, fast: Bool) {
        var index = 0
        let fast = args.first == "--fast"
        if fast { index += 1 }
        let literal = index < args.count && args[index] == "--"
        if literal { index += 1 }
        guard args.count == index + 1, literal || !args[index].hasPrefix("--") else {
            throw CUAError(message: "usage: macos-cua type [--fast] [--] <one text>")
        }
        guard args[index].utf16.count <= 8192 else { throw CUAError(message: "typed text must contain at most 8192 UTF-16 units") }
        return (args[index], fast)
    }

    static func parseWait(_ args: [String]) throws -> Int {
        guard args.count == 1 else { throw CUAError(message: "usage: macos-cua wait <ms>") }
        let ms = try parseInt(args[0], name: "ms")
        guard (0...20000).contains(ms) else { throw CUAError(message: "wait requires milliseconds in 0...20000") }
        return ms
    }

    static func validatePNGPath(_ path: String) throws {
        guard !path.hasPrefix("--") else { throw CUAError(message: "capture requires a .png output path") }
        _ = try ScreenshotSupport.validateOutputPath(path)
    }

    static func requireActivation(_ payload: [String: Any], subject: String) throws {
        guard payload["ok"] as? Bool == true else {
            throw CUAError(message: "failed to activate \(subject)", code: "activation_failed",
                           resultJSON: try JSONSerialization.data(withJSONObject: normalizeJSONValue(payload)))
        }
    }

    static func captureAfterClick(_ capture: () throws -> [String: Any]) throws -> [String: Any] {
        do {
            return try capture()
        } catch {
            throw CUAError(message: "click already occurred; post-click capture failed: \(error.localizedDescription)",
                           code: "post_crop_failed",
                           resultJSON: try JSONSerialization.data(withJSONObject: ["clickOccurred": true, "captureFailed": true]))
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

    static func doctorReady(accessibility: Bool, screenRecording: Bool, screenshotCheck: [String: Any]) -> Bool {
        accessibility && screenRecording && screenshotCheck["ok"] as? Bool == true
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
                    context: CoordinateSupport.context(explicitScreen: true, relative: false)
                )
                try FileManager.default.removeItem(at: tempPath)
                screenshotCheck = ["ok": true]
            } catch {
                screenshotCheck = ["ok": false, "error": error.localizedDescription]
            }
        }

        let payload: [String: Any] = [
            "accessibility": accessibility,
            "screenRecording": screenRecording,
            "syntheticInputReady": accessibility,
            "screenshotReady": screenshotCheck,
            "allReady": doctorReady(accessibility: accessibility, screenRecording: screenRecording, screenshotCheck: screenshotCheck),
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
            lines.append("Next: run `macos-cua onboard` to request missing permissions in this execution context.")
        } else if let error = screenshotCheck["error"] as? String {
            lines.append("Capture probe failed: \(error)")
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
        ], lines: cursorPositionLines(pointerScreen: pointerScreen, context: context))
    }

    static func screenSize(output: CLIOutput) throws {
        let actionSpace = try InputSupport.actionSpace()
        try output.emit(["actionSpace": actionSpace], human: screenSizeLine(actionSpace))
    }

    static func cursorPositionLines(pointerScreen: CGPoint, context: CoordinateContext) -> [String] {
        let local = context.pointerWindowPoint(fromScreenPoint: pointerScreen)
        return [
            "Pointer (screen-global logical points): \(Int(pointerScreen.x.rounded())),\(Int(pointerScreen.y.rounded()))",
            "Pointer (window-local logical points): \(local.map { "\(Int($0.x.rounded())),\(Int($0.y.rounded()))" } ?? "n/a")",
            "Default coordinates: \(context.summary)",
        ]
    }

    static func screenSizeLine(_ actionSpace: [String: Any]) -> String {
        "Primary screen: \(actionSpace["width"] ?? "?")x\(actionSpace["height"] ?? "?") logical points, origin \(actionSpace["x"] ?? "?"),\(actionSpace["y"] ?? "?")"
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
        guard ok else { throw CUAError(message: "failed to open URL: \(url.absoluteString)", code: "open_url_failed") }
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
        let requestedTarget = try options.remaining.dropFirst().first.map(ScreenshotSupport.target(named:))
        let explicitScreen = options.explicitScreen || requestedTarget == .screen
        let coordinateContext = CoordinateSupport.context(explicitScreen: explicitScreen, relative: relative)
        let target = try screenshotTarget(options: options, context: coordinateContext)
        var payload = try ScreenshotSupport.capture(
            target: target, path: options.remaining[0], context: coordinateContext
        )
        let image = payload["image"] as? [String: Any]
        payload["width"] = image?["width"]
        payload["height"] = image?["height"]
        let bounds = payload["bounds"] as? [String: Any]
        let summary = (payload["coordinateSpace"] as? String ?? coordinateContext.coordinateSpaceName)
            + ((payload["coordinateFallback"] as? Bool) == true ? " fallback" : "")
        let human = "captured \(payload["target"] as? String ?? "screenshot") to \(options.remaining[0]) (\(image?["width"] ?? "?")x\(image?["height"] ?? "?"), \(summary), bounds \(bounds?["x"] ?? "?"),\(bounds?["y"] ?? "?") \(bounds?["width"] ?? "?")x\(bounds?["height"] ?? "?"))"
        try output.emit(payload, human: human)
    }

    static func screenshotTarget(
        options: (remaining: [String], explicitScreen: Bool, region: CGRect?),
        context: CoordinateContext
    ) throws -> ScreenshotTarget {
        if let region = options.region { return .region(try context.inputRect(region).screen) }
        if let name = options.remaining.dropFirst().first { return try ScreenshotSupport.target(named: name) }
        return options.explicitScreen ? .screen : .frontmostWindow
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
        let observedPoint = InputSupport.currentPointer()
        var payload = coordinateContext.actionPayload(x: x, y: y, screenPoint: observedPoint)
        payload["profile"] = profile.rawValue
        if let feedback = AccessibilitySupport.feedback(for: observedPoint, context: coordinateContext) {
            for (key, value) in feedback {
                payload[key] = value
            }
        }
        var human = "moved pointer to \(x),\(y) [\(relative ? "relative, " : "")\(coordinateContext.summary), screen \(Int(observedPoint.x.rounded())),\(Int(observedPoint.y.rounded()))] [\(profile.rawValue)]"
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
        let observedPoint = InputSupport.currentPointer()
        var payload = coordinateContext.actionPayload(x: x, y: y, screenPoint: observedPoint)
        payload["button"] = button.rawValue
        payload["profile"] = profile.rawValue
        payload["mouseAction"] = "mousedown"
        let human = "mousedown \(button.rawValue) at \(x),\(y) [\(relative ? "relative, " : "")\(coordinateContext.summary), screen \(Int(observedPoint.x.rounded())),\(Int(observedPoint.y.rounded()))] [\(profile.rawValue)]"
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
        let observedPoint = InputSupport.currentPointer()
        let payload: [String: Any] = [
            "accepted": true,
            "pointerScreen": CoordinateSupport.pointJSON(observedPoint),
            "inputUnits": NSNull(),
        ]
        if let postCropPath {
            let debugPayload = try captureAfterClick {
                var debugPayload = payload
                guard let bounds = coordinateContext.cropBounds(),
                      let crop = ScreenshotSupport.cropRect(centeredAt: observedPoint, within: bounds) else {
                    throw CUAError(message: "no valid post-click crop bounds")
                }
                let plan = try ScreenshotSupport.plan(target: .region(crop), context: coordinateContext)
                let cropPoint = CGPoint(x: observedPoint.x - plan.screenBounds.origin.x,
                                        y: observedPoint.y - plan.screenBounds.origin.y)
                let cropPayload = try ScreenshotSupport.capture(plan: plan, path: postCropPath, markerPoint: cropPoint)
                debugPayload["postCropPath"] = cropPayload["path"]
                debugPayload["postCropBounds"] = cropPayload["bounds"]
                debugPayload["postCropOrigin"] = CoordinateSupport.pointJSON(plan.reportedBounds.origin)
                debugPayload["postCropClickPoint"] = CoordinateSupport.pointJSON(cropPoint)
                return debugPayload
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
        let options = try parseTypeOptions(args)
        try InputSupport.typeText(options.text, fast: options.fast)
        try output.emit(
            [
                "accepted": true,
                "pointerScreen": NSNull(),
                "inputUnits": options.text.utf16.count,
            ],
            human: "typed \(options.text.count) characters"
        )
    }

    static func wait(args: [String], output: CLIOutput) throws {
        let ms = try parseWait(args)
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
            guard args.count == 2 else {
                throw CUAError(message: "usage: macos-cua app activate <name-or-bundle-id>")
            }
            let query = args[1]
            let payload = try AppSupport.activate(query: query)
            try requireActivation(payload, subject: "app \(query)")
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
            let id = try parseWindowID(args[1])
            let payload = try WindowSupport.activateWindow(id: id)
            try requireActivation(payload, subject: "window \(id)")
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
                if explicit {
                    throw CUAError(message: usage)
                }
                selected = .fast
                explicit = true
            case "--precise":
                if explicit {
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
                guard !arg.hasPrefix("--") else { throw CUAError(message: "unsupported option: \(arg)") }
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
                if explicit { throw CUAError(message: usage) }
                selected = .fast
                explicit = true
                index += 1
            case "--precise":
                if explicit { throw CUAError(message: usage) }
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
                try validatePNGPath(args[index + 1])
                postCropPath = args[index + 1]
                index += 2
            default:
                guard !args[index].hasPrefix("--") else { throw CUAError(message: "unsupported option: \(args[index])") }
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
                guard x >= 0, y >= 0, width > 0, height > 0 else { throw CUAError(message: "region requires nonnegative origin and positive size") }
                region = CGRect(x: x, y: y, width: width, height: height)
                index += 5
            default:
                guard !args[index].hasPrefix("--") else { throw CUAError(message: "unsupported option: \(args[index])") }
                remaining.append(args[index])
                index += 1
            }
        }
        guard (1...2).contains(remaining.count) else { throw CUAError(message: "usage: macos-cua screenshot [--screen] [--region x y w h] <path.png> [window|screen]") }
        try validatePNGPath(remaining[0])
        if remaining.count == 2 {
            _ = try ScreenshotSupport.target(named: remaining[1])
            guard region == nil, !explicitScreen else { throw CUAError(message: "positional screenshot target conflicts with --region or --screen") }
        }
        return (remaining, explicitScreen, region)
    }

    static func applyBlockingModalState(_ blockingModalState: WindowSupport.BlockingModalState, to payload: inout [String: Any]) {
        for (key, value) in blockingModalState.payload {
            payload[key] = value
        }
    }
}
