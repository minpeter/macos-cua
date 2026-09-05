import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum MouseButtonName: String {
    case left
    case right
    case middle

    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    var downType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    var upType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }

    var dragType: CGEventType {
        switch self {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .middle: return .otherMouseDragged
        }
    }
}

enum InputSupport {
    static let keycodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "esc": 53, "escape": 53, "cmd": 55, "command": 55, "shift": 56,
        "capslock": 57, "option": 58, "alt": 58, "control": 59, "ctrl": 59,
        "rightshift": 60, "rightoption": 61, "rightcontrol": 62, "fn": 63, "function": 63,
        "f17": 64, "volumeup": 72, "volumedown": 73, "mute": 74, "f18": 79, "f19": 80,
        "f20": 90, "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101,
        "f11": 103, "f13": 105, "f16": 106, "f14": 107, "f10": 109, "f12": 111,
        "f15": 113, "help": 114, "home": 115, "pageup": 116, "forwarddelete": 117,
        "f4": 118, "end": 119, "f2": 120, "pagedown": 121, "f1": 122, "left": 123,
        "right": 124, "down": 125, "up": 126
    ]

    static let modifierMapping: [(String, CGEventFlags)] = [
        ("cmd", .maskCommand),
        ("command", .maskCommand),
        ("shift", .maskShift),
        ("alt", .maskAlternate),
        ("option", .maskAlternate),
        ("ctrl", .maskControl),
        ("control", .maskControl),
        ("fn", .maskSecondaryFn),
        ("function", .maskSecondaryFn),
    ]

    static func mouseButton(named raw: String) throws -> MouseButtonName {
        guard let value = MouseButtonName(rawValue: raw.lowercased()) else {
            throw CUAError(message: "unsupported mouse button: \(raw)")
        }
        return value
    }

    static func post(_ event: CGEvent?) throws {
        try PermissionSupport.require(.accessibility, for: "synthetic input")
        guard let event else {
            throw CUAError(message: "failed to create CGEvent")
        }
        event.post(tap: .cghidEventTap)
    }

    static func currentPointer(event: CGEvent? = CGEvent(source: nil)) -> CGPoint {
        if let event {
            return event.location
        }
        // Cocoa uses a bottom-left origin on the primary display, not the active display.
        let point = NSEvent.mouseLocation
        return CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
    }

    static func actionSpace() throws -> [String: Any] {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        guard !bounds.isEmpty else {
            throw CUAError(message: "no primary screen is available")
        }
        return [
            "x": Int(bounds.minX.rounded()),
            "y": Int(bounds.minY.rounded()),
            "width": Int(bounds.width.rounded()),
            "height": Int(bounds.height.rounded()),
        ]
    }

    static func sendMouseMove(to point: CGPoint) throws {
        let button = activeMouseButton() ?? .left
        let type = activeMouseButton().map(\.dragType) ?? .mouseMoved
        try post(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button.cgButton))
    }

    static func performMotion(to point: CGPoint, profile: PointerMotionProfile, kind: PointerMotionKind, seed: UInt64? = nil) throws -> PointerMotionPlan {
        let request = PointerMotionRequest(
            start: currentPointer(),
            end: point,
            profile: profile,
            kind: kind,
            seed: seed
        )
        let plan = PointerMotionEngine.buildPlan(request)
        for sample in plan.samples {
            try sendMouseMove(to: sample.point)
            if sample.delayMicros > 0 {
                usleep(sample.delayMicros)
            }
        }
        return plan
    }

    static func click(
        point: CGPoint, button: MouseButtonName, count: Int, profile: PointerMotionProfile, seed: UInt64? = nil,
        move: (CGPoint, PointerMotionProfile, PointerMotionKind, UInt64?) throws -> PointerMotionPlan = {
            try performMotion(to: $0, profile: $1, kind: $2, seed: $3)
        },
        pointer: () -> CGPoint = { currentPointer() },
        postEvent: (CGEvent?) throws -> Void = post
    ) throws {
        let plan = try move(point, profile, count == 2 ? .doubleClick : .click, seed)
        for clickIndex in 1...count {
            try mouseDown(at: point, button: button, clickState: Int64(clickIndex), pointer: pointer, postEvent: postEvent)
            try mouseUp(at: point, button: button, clickState: Int64(clickIndex), postEvent: postEvent)
            if clickIndex < count {
                usleep(plan.interClickDelayMicros ?? 75_000)
            }
        }
    }

    static func mouseDown(
        at point: CGPoint, button: MouseButtonName, clickState: Int64 = 1,
        pointer: () -> CGPoint = { currentPointer() }, postEvent: (CGEvent?) throws -> Void = post
    ) throws {
        let observed = pointer()
        // Fractional logical points may be quantized by WindowServer, but a different
        // logical pixel (including a clamped monitor edge) must never receive the click.
        guard observed.x.isFinite, observed.y.isFinite,
              abs(observed.x - point.x) < 0.5, abs(observed.y - point.y) < 0.5 else {
            throw CUAError(message: "pointer did not reach the requested position; mouse-down was not sent (requested \(point.x),\(point.y), observed \(observed.x),\(observed.y))")
        }
        let down = CGEvent(mouseEventSource: nil, mouseType: button.downType, mouseCursorPosition: point, mouseButton: button.cgButton)
        down?.setIntegerValueField(.mouseEventClickState, value: clickState)
        try postEvent(down)
    }

    static func mouseUp(at point: CGPoint, button: MouseButtonName, clickState: Int64 = 1, postEvent: (CGEvent?) throws -> Void = post) throws {
        let up = CGEvent(mouseEventSource: nil, mouseType: button.upType, mouseCursorPosition: point, mouseButton: button.cgButton)
        up?.setIntegerValueField(.mouseEventClickState, value: clickState)
        try postEvent(up)
    }

    static func scroll(dx: Int, dy: Int, postEvent: (CGEvent?) throws -> Void = post) throws {
        guard let deltaX = Int32(exactly: dx), let deltaY = Int32(exactly: dy) else {
            throw CUAError(message: "scroll deltas must be signed 32-bit integers")
        }
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        )
        try postEvent(event)
    }

    static func currentModifierNames() -> [String] {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        var names: [String] = []
        if flags.contains(.maskCommand) { names.append("cmd") }
        if flags.contains(.maskShift) { names.append("shift") }
        if flags.contains(.maskAlternate) { names.append("option") }
        if flags.contains(.maskControl) { names.append("control") }
        if flags.contains(.maskSecondaryFn) { names.append("fn") }
        return names
    }

    static func currentMouseButtons() -> [String] {
        var buttons: [String] = []
        if CGEventSource.buttonState(.combinedSessionState, button: .left) { buttons.append("left") }
        if CGEventSource.buttonState(.combinedSessionState, button: .right) { buttons.append("right") }
        if CGEventSource.buttonState(.combinedSessionState, button: .center) { buttons.append("middle") }
        return buttons
    }

    static func activeMouseButton() -> MouseButtonName? {
        if CGEventSource.buttonState(.combinedSessionState, button: .left) { return .left }
        if CGEventSource.buttonState(.combinedSessionState, button: .right) { return .right }
        if CGEventSource.buttonState(.combinedSessionState, button: .center) { return .middle }
        return nil
    }

    static func keycode(for token: String) throws -> CGKeyCode {
        guard let code = keycodes[token.lowercased()] else {
            throw CUAError(message: "unsupported key token: \(token)")
        }
        return code
    }

    static func modifierFlagsAndRemainder(_ combo: String) -> (CGEventFlags, [String]) {
        var flags: CGEventFlags = []
        var remainder: [String] = []
        for part in combo.split(separator: "+").map(String.init) {
            let token = part.lowercased()
            if let flag = modifierMapping.first(where: { $0.0 == token })?.1 {
                flags.insert(flag)
            } else if !token.isEmpty {
                remainder.append(token)
            }
        }
        return (flags, remainder)
    }

    static func keypress(_ combo: String, postEvent: (CGEvent?) throws -> Void = post) throws {
        let parts = combo.split(separator: "+", omittingEmptySubsequences: false)
        guard !parts.contains(where: \.isEmpty) else {
            throw CUAError(message: "keypress requires nonempty key tokens separated by +")
        }
        let (flags, remainder) = modifierFlagsAndRemainder(combo)
        guard remainder.count <= 1 else {
            throw CUAError(message: "keypress accepts at most one nonmodifier key")
        }
        // Resolve the entire combination before posting even the first modifier.
        let mainCode = try remainder.first.map { try keycode(for: $0) }
        let modifierOrder: [(String, CGEventFlags)] = [
            ("command", .maskCommand),
            ("shift", .maskShift),
            ("option", .maskAlternate),
            ("control", .maskControl),
            ("function", .maskSecondaryFn),
        ]

        guard let code = mainCode else {
            for (name, flag) in modifierOrder where flags.contains(flag) {
                let code = try keycode(for: name)
                let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
                down?.flags = flag
                try postEvent(down)
                let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
                up?.flags = []
                try postEvent(up)
            }
            return
        }

        var activeFlags: CGEventFlags = []
        for (name, flag) in modifierOrder where flags.contains(flag) {
            let code = try keycode(for: name)
            activeFlags.insert(flag)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
            down?.flags = activeFlags
            try postEvent(down)
        }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        down?.flags = flags
        try postEvent(down)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        up?.flags = flags
        try postEvent(up)

        for (name, flag) in modifierOrder.reversed() where flags.contains(flag) {
            let code = try keycode(for: name)
            activeFlags.remove(flag)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
            up?.flags = activeFlags
            try postEvent(up)
        }
    }

    static func typeText(
        _ text: String, fast: Bool,
        pause: (UInt32) -> Void = { usleep($0) },
        postEvent: (CGEvent?) throws -> Void = post
    ) throws {
        guard text.utf16.count <= 8_192 else {
            throw CUAError(message: "typed text must contain at most 8192 UTF-16 units")
        }
        let units = Array(text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").utf16)
        // CG keyboard Unicode payloads hold at most 20 UTF-16 units. Batch ASCII and
        // Unicode identically: no pasteboard ownership, format loss or restoration race.
        let batchSize = fast ? 20 : 8
        var start = 0
        while start < units.count {
            var end = min(start + batchSize, units.count)
            if end < units.count && (0xD800...0xDBFF).contains(units[end - 1]) {
                end -= 1
            }
            let batch = Array(units[start..<end])
            let down = try requireValue(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true), "failed to create text key-down")
            let up = try requireValue(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false), "failed to create text key-up")
            for event in [down, up] {
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: batch.count, unicodeString: batch)
                try postEvent(event)
            }
            // A fixed per-batch budget keeps both modes comfortably below the 20s
            // sidecar timeout, unlike random per-character delays (up to 15 minutes).
            pause(fast ? 1_000 : 2_000)
            start = end
        }
    }

    // Historical classifier retained for callers; text delivery no longer uses paste.
    static func requiresClipboardPaste(_ text: String) -> Bool {
        !text.unicodeScalars.allSatisfy(\.isASCII)
    }
}
