import AppKit
import CoreGraphics
import Foundation

enum CoordinateSpaceName: String {
    case window
    case screen
}

enum CoordinateValueMode {
    case absolute
    case relative
}

struct ResolvedActionPoint {
    let local: CGPoint
    let screen: CGPoint
}

struct ResolvedActionRect {
    let local: CGRect
    let screen: CGRect
}

private struct CoordinateResolution {
    let coordinateSpace: CoordinateSpaceName
    let coordinateFallback: Bool
    let window: WindowRecord?
    let primaryBounds: CGRect?
    let displayBounds: [CGRect]

    var windowBounds: CGRect? {
        window?.bounds
    }

    func translate(point: CGPoint) -> CGPoint {
        guard coordinateSpace == .window, let bounds = windowBounds else {
            return point
        }
        return CGPoint(x: bounds.origin.x + point.x, y: bounds.origin.y + point.y)
    }

    func translate(rect: CGRect) -> CGRect {
        CGRect(origin: translate(point: rect.origin), size: rect.size)
    }

    func localPoint(fromScreenPoint point: CGPoint) -> CGPoint {
        guard coordinateSpace == .window, let bounds = windowBounds else {
            return point
        }
        return CGPoint(x: point.x - bounds.origin.x, y: point.y - bounds.origin.y)
    }

    func localRect(fromScreenRect rect: CGRect) -> CGRect {
        CGRect(origin: localPoint(fromScreenPoint: rect.origin), size: rect.size)
    }

    func screenshotBounds(for target: ScreenshotTarget) -> CGRect? {
        switch target {
        case .frontmostWindow:
            guard let bounds = windowBounds else { return primaryBounds }
            if coordinateSpace == .window {
                return CGRect(origin: .zero, size: bounds.size)
            }
            return bounds
        case .screen:
            return primaryBounds
        case .region(let rect):
            return rect
        }
    }
}

struct CoordinateContext {
    fileprivate let resolution: CoordinateResolution
    fileprivate let valueMode: CoordinateValueMode

    var coordinateSpace: CoordinateSpaceName { resolution.coordinateSpace }
    var coordinateSpaceName: String { resolution.coordinateSpace.rawValue }
    var coordinateFallback: Bool { resolution.coordinateFallback }
    var isRelative: Bool { valueMode == .relative }
    var usesWindowCoordinates: Bool { coordinateSpace == .window }
    var windowBounds: CGRect? { resolution.windowBounds }
    var frontmostWindow: WindowRecord? { resolution.window }
    var primaryBounds: CGRect? { resolution.primaryBounds }
    var displayBounds: [CGRect] { resolution.displayBounds }
    var summary: String {
        coordinateFallback ? "\(coordinateSpaceName) fallback" : coordinateSpaceName
    }

    func inputPoint(x: Int, y: Int) throws -> ResolvedActionPoint {
        let raw = CGPoint(x: x, y: y)
        if isRelative {
            try CoordinateSupport.validateRelativePoint(raw)
        }
        let local = isRelative ? CoordinateSupport.denormalize(raw, resolution: resolution) : raw
        try CoordinateSupport.validatePoint(local, resolution: resolution)
        return ResolvedActionPoint(local: local, screen: resolution.translate(point: local))
    }

    func inputRect(_ rect: CGRect) throws -> ResolvedActionRect {
        try CoordinateSupport.validateRectGeometry(rect)
        if isRelative {
            try CoordinateSupport.validateRelativeRect(rect)
        }
        let local = isRelative ? CoordinateSupport.denormalize(rect, resolution: resolution) : rect
        let extent = CGRect(origin: .zero, size: CoordinateSupport.referenceSize(for: resolution))
        guard extent.contains(local) else {
            throw CUAError(message: "region is outside the \(coordinateSpaceName)")
        }
        let screen = resolution.translate(rect: local)
        guard displayBounds.contains(where: { $0.intersects(screen) }) else {
            throw CUAError(message: "region does not intersect an active display")
        }
        return ResolvedActionRect(local: local, screen: screen)
    }

    func outputPoint(fromScreenPoint point: CGPoint) -> CGPoint {
        outputPoint(fromLocalPoint: resolution.localPoint(fromScreenPoint: point))
    }

    func outputPoint(fromLocalPoint point: CGPoint) -> CGPoint {
        guard isRelative else { return point }
        return CoordinateSupport.normalize(point, resolution: resolution)
    }

    func outputRect(fromScreenRect rect: CGRect) -> CGRect {
        outputRect(fromLocalRect: resolution.localRect(fromScreenRect: rect))
    }

    func outputRect(fromLocalRect rect: CGRect) -> CGRect {
        guard isRelative else { return rect }
        return CoordinateSupport.normalize(rect, resolution: resolution)
    }

    func outputPointJSON(fromScreenPoint point: CGPoint) -> [String: Any] {
        CoordinateSupport.pointJSON(outputPoint(fromScreenPoint: point))
    }

    func outputPointJSON(fromLocalPoint point: CGPoint) -> [String: Any] {
        CoordinateSupport.pointJSON(outputPoint(fromLocalPoint: point))
    }

    func outputRectJSON(fromScreenRect rect: CGRect) -> [String: Any] {
        CoordinateSupport.rectJSON(outputRect(fromScreenRect: rect))
    }

    func outputRectJSON(fromLocalRect rect: CGRect) -> [String: Any] {
        CoordinateSupport.rectJSON(outputRect(fromLocalRect: rect))
    }

    func pointerWindowPoint(fromScreenPoint point: CGPoint) -> CGPoint? {
        guard windowBounds != nil else { return nil }
        return resolution.localPoint(fromScreenPoint: point)
    }

    func screenshotReportedBounds(for target: ScreenshotTarget) -> CGRect? {
        resolution.screenshotBounds(for: target).map { outputRect(fromLocalRect: $0) }
    }

    func cropBounds() -> CGRect? {
        coordinateSpace == .window ? windowBounds : primaryBounds
    }

    func applyMetadata(to payload: inout [String: Any]) {
        payload["coordinateSpace"] = coordinateSpaceName
        payload["coordinateFallback"] = coordinateFallback
        payload["coordinateUnits"] = "logical-points"
        if isRelative {
            payload["relative"] = true
        }
    }

    func statePayload(
        pointerScreen: CGPoint,
        actionSpace: [String: Any],
        held: [String: Any],
        releaseHints: [String],
        frontmostApp: [String: Any]?,
        frontmostWindow: [String: Any]?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "defaultCoordinateSpace": coordinateSpaceName,
            "defaultCoordinateFallback": coordinateFallback,
            "pointerScreen": CoordinateSupport.pointJSON(pointerScreen),
            "pointerWindow": pointerWindowPoint(fromScreenPoint: pointerScreen).map(CoordinateSupport.pointJSON) as Any,
            "held": held,
            "releaseHints": releaseHints,
            "frontmostApp": frontmostApp as Any,
            "frontmostWindow": frontmostWindow as Any,
            "actionSpace": actionSpace,
        ]
        if isRelative {
            payload["pointerRelative"] = outputPointJSON(fromScreenPoint: pointerScreen)
            payload["relative"] = true
        }
        return payload
    }

    func actionPayload(x: Int, y: Int, screenPoint: CGPoint) -> [String: Any] {
        var payload: [String: Any] = [
            "x": x,
            "y": y,
            "screenPoint": CoordinateSupport.pointJSON(screenPoint),
        ]
        applyMetadata(to: &payload)
        return payload
    }
}

enum CoordinateSupport {
    // Reference dimensions for relative coordinate scaling (1000 == full width or height).
    fileprivate static func referenceSize(for resolution: CoordinateResolution) -> CGSize {
        switch resolution.coordinateSpace {
        case .window:
            if let size = resolution.window?.bounds.size, size.width > 0, size.height > 0 {
                return size
            }
            fallthrough
        case .screen:
            return resolution.primaryBounds?.size ?? .zero
        }
    }

    static func context(
        explicitScreen: Bool,
        relative: Bool,
        frontmostWindow: WindowRecord? = WindowSupport.frontmostWindow(),
        primaryBounds: CGRect? = ScreenshotSupport.screenBounds(),
        displayBounds: [CGRect] = ScreenshotSupport.displayBounds()
    ) -> CoordinateContext {
        // Resolve geometry once; focus/display changes must not alter an invocation halfway through.
        let usableWindow = frontmostWindow.flatMap { window -> WindowRecord? in
            let bounds = window.bounds
            return window.onScreen && isValidRectGeometry(bounds) ? window : nil
        }
        return CoordinateContext(
            resolution: CoordinateResolution(
                coordinateSpace: explicitScreen || usableWindow == nil ? .screen : .window,
                coordinateFallback: !explicitScreen && usableWindow == nil,
                window: usableWindow, primaryBounds: primaryBounds, displayBounds: displayBounds
            ),
            valueMode: relative ? .relative : .absolute
        )
    }

    // Convert a [0, 1000] relative rect (origin + size all relative) to absolute local space.
    fileprivate static func denormalize(_ relative: CGRect, resolution: CoordinateResolution) -> CGRect {
        let ref = referenceSize(for: resolution)
        guard ref.width > 0, ref.height > 0 else { return .zero }
        return CGRect(
            x: relative.origin.x * ref.width / 1000,
            y: relative.origin.y * ref.height / 1000,
            width: relative.width * ref.width / 1000,
            height: relative.height * ref.height / 1000
        )
    }

    // Convert a [0, 1000] relative point to an absolute point in the resolution's local space.
    fileprivate static func denormalize(_ relative: CGPoint, resolution: CoordinateResolution) -> CGPoint {
        let ref = referenceSize(for: resolution)
        guard ref.width > 0, ref.height > 0 else { return .zero }
        let maxX = max(ref.width - 1, 0)
        let maxY = max(ref.height - 1, 0)
        return CGPoint(x: relative.x * maxX / 1000, y: relative.y * maxY / 1000)
    }

    // Convert an absolute local-space point to [0, 1000] relative.
    fileprivate static func normalize(_ absolute: CGPoint, resolution: CoordinateResolution) -> CGPoint {
        let ref = referenceSize(for: resolution)
        guard ref.width > 0, ref.height > 0 else { return .zero }
        let maxX = max(ref.width - 1, 1)
        let maxY = max(ref.height - 1, 1)
        return CGPoint(
            x: min(max((absolute.x / maxX * 1000).rounded(), 0), 1000),
            y: min(max((absolute.y / maxY * 1000).rounded(), 0), 1000)
        )
    }

    // Convert an absolute local-space rect to [0, 1000] relative.
    fileprivate static func normalize(_ absolute: CGRect, resolution: CoordinateResolution) -> CGRect {
        let ref = referenceSize(for: resolution)
        guard ref.width > 0, ref.height > 0 else { return .zero }
        return CGRect(
            x: (absolute.origin.x / ref.width * 1000).rounded(),
            y: (absolute.origin.y / ref.height * 1000).rounded(),
            width: (absolute.width / ref.width * 1000).rounded(),
            height: (absolute.height / ref.height * 1000).rounded()
        )
    }

    static func pointJSON(_ point: CGPoint) -> [String: Any] {
        ["x": Int(point.x.rounded()), "y": Int(point.y.rounded())]
    }

    static func rectJSON(_ rect: CGRect) -> [String: Any] {
        [
            "x": Int(rect.origin.x.rounded()),
            "y": Int(rect.origin.y.rounded()),
            "width": Int(rect.width.rounded()),
            "height": Int(rect.height.rounded()),
        ]
    }

    static func validateRelativePoint(_ point: CGPoint) throws {
        try validateRelativeValue(Int(point.x.rounded()), name: "x")
        try validateRelativeValue(Int(point.y.rounded()), name: "y")
    }

    fileprivate static func validatePoint(_ point: CGPoint, resolution: CoordinateResolution) throws {
        let size = referenceSize(for: resolution)
        guard point.x >= 0, point.y >= 0, point.x < size.width, point.y < size.height else {
            throw CUAError(message: "coordinate is outside the \(resolution.coordinateSpace.rawValue): x=\(point.x), y=\(point.y)")
        }
        let screen = resolution.translate(point: point)
        guard resolution.displayBounds.contains(where: { bounds in
            screen.x >= bounds.minX && screen.y >= bounds.minY && screen.x < bounds.maxX && screen.y < bounds.maxY
        }) else {
            throw CUAError(message: "coordinate is not on an active display: x=\(screen.x), y=\(screen.y)")
        }
    }

    static func isValidRectGeometry(_ rect: CGRect) -> Bool {
        let values = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height, rect.maxX, rect.maxY]
        return values.allSatisfy { $0.isFinite && abs($0) <= CGFloat(Int32.max) }
            && rect.size.width > 0 && rect.size.height > 0
    }

    static func validateRectGeometry(_ rect: CGRect) throws {
        guard isValidRectGeometry(rect) else {
            throw CUAError(message: "region requires finite coordinates and positive width/height within signed 32-bit range")
        }
    }

    static func validateRelativeRect(_ rect: CGRect) throws {
        try validateRectGeometry(rect)
        let x = Int(rect.origin.x.rounded())
        let y = Int(rect.origin.y.rounded())
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        try validateRelativeValue(x, name: "x")
        try validateRelativeValue(y, name: "y")
        try validateRelativeValue(width, name: "width")
        try validateRelativeValue(height, name: "height")

        if x + width > 1000 {
            throw CUAError(message: "--relative requires integer coordinates in [0, 1000]; got x + width = \(x + width) (x=\(x), width=\(width))")
        }
        if y + height > 1000 {
            throw CUAError(message: "--relative requires integer coordinates in [0, 1000]; got y + height = \(y + height) (y=\(y), height=\(height))")
        }
    }

    private static func validateRelativeValue(_ value: Int, name: String) throws {
        guard (0...1000).contains(value) else {
            throw CUAError(message: "--relative requires integer coordinates in [0, 1000]; got \(name)=\(value)")
        }
    }
}
