import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Darwin

enum ScreenshotTarget: Equatable {
    case frontmostWindow
    case screen
    case region(CGRect)
}

// A capture uses this immutable snapshot for acquisition, normalization, and metadata.
struct ScreenshotCapturePlan {
    let requestedTarget: ScreenshotTarget
    let target: ScreenshotTarget
    let windowID: Int?
    let screenBounds: CGRect
    let reportedBounds: CGRect
    let primaryBounds: CGRect
    let coordinateSpace: CoordinateSpaceName
    let coordinateFallback: Bool
    let relative: Bool

    var content: String { windowID == nil ? "visible-desktop" : "window-surface" }
    var captureMethod: String { windowID != nil ? "window-id" : target == .screen ? "primary-display" : "region" }

    func arguments(outputPath: String) -> [String] {
        let prefix = ["-x", "-t", "png"]
        if let windowID {
            return prefix + ["-o", "-l", String(windowID), outputPath]
        }
        if target == .screen { return prefix + ["-m", outputPath] }
        let region = "\(Int(screenBounds.minX)),\(Int(screenBounds.minY)),\(Int(screenBounds.width)),\(Int(screenBounds.height))"
        return prefix + ["-R\(region)", outputPath]
    }
}

// Inject only external acquisition/permission boundaries. PNG decoding, scaling, and publication stay real.
struct ScreenshotCaptureEnvironment {
    var requirePermission: () throws -> Void = {
        try PermissionSupport.require(.screenRecording, for: "screenshots")
    }
    var runCapture: ([String]) throws -> Void = ScreenshotSupport.runCapture
}

enum ScreenshotSupport {
    static func target(named name: String) throws -> ScreenshotTarget {
        switch name {
        case "window": return .frontmostWindow
        case "screen": return .screen
        default:
            throw CUAError(message: "invalid screenshot target: \(name); expected window or screen")
        }
    }

    static func screenCaptureAccess() -> Bool {
        PermissionSupport.isGranted(.screenRecording)
    }

    static func ensureDirectory(for path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    static func validateOutputPath(_ path: String) throws -> URL {
        guard !path.hasSuffix("/"), !path.contains("\0") else {
            throw CUAError(message: "screenshot requires a .png file path")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension.lowercased() == "png" else {
            throw CUAError(message: "screenshot currently requires a .png output path")
        }
        return url
    }

    static func plan(target: ScreenshotTarget, context: CoordinateContext) throws -> ScreenshotCapturePlan {
        let primary = try requireValue(context.primaryBounds, "no primary display is available")
        let effectiveTarget: ScreenshotTarget
        let bounds: CGRect
        let windowID: Int?
        switch target {
        case .frontmostWindow:
            if let window = context.frontmostWindow {
                effectiveTarget = .frontmostWindow
                bounds = window.bounds
                windowID = window.id
            } else {
                effectiveTarget = .screen
                bounds = primary
                windowID = nil
            }
        case .screen:
            effectiveTarget = .screen
            bounds = primary
            windowID = nil
        case .region(let rect):
            effectiveTarget = target
            bounds = rect
            windowID = nil
        }
        try CoordinateSupport.validateRectGeometry(bounds)
        // screencapture accepts integer logical units. Round edges once and advertise exactly those edges.
        let rounded = CGRect(x: bounds.minX.rounded(), y: bounds.minY.rounded(),
            width: bounds.maxX.rounded() - bounds.minX.rounded(),
            height: bounds.maxY.rounded() - bounds.minY.rounded())
        try CoordinateSupport.validateRectGeometry(rounded)
        if windowID == nil, !context.displayBounds.contains(where: { $0.intersects(rounded) }) {
            throw CUAError(message: "capture region does not intersect an active display")
        }
        let fallback = target == .frontmostWindow && effectiveTarget == .screen
        let space: CoordinateSpaceName = effectiveTarget == .screen ? .screen : context.coordinateSpace
        let reported = effectiveTarget == .screen
            ? (context.isRelative ? CGRect(x: 0, y: 0, width: 1000, height: 1000) : rounded)
            : context.outputRect(fromScreenRect: rounded)
        return ScreenshotCapturePlan(requestedTarget: target, target: effectiveTarget, windowID: windowID,
            screenBounds: rounded, reportedBounds: reported, primaryBounds: primary,
            coordinateSpace: space, coordinateFallback: fallback || context.coordinateFallback,
            relative: context.isRelative)
    }

    static func capture(
        target: ScreenshotTarget, path: String, context: CoordinateContext, markerPoint: CGPoint? = nil
    ) throws -> [String: Any] {
        try capture(plan: plan(target: target, context: context), path: path, markerPoint: markerPoint)
    }

    // Compatibility for recorder/doctor callers. New callers should pass their already-resolved context.
    static func capture(
        target: ScreenshotTarget,
        path: String,
        coordinateSpace: CoordinateSpaceName,
        coordinateFallback: Bool,
        reportedBounds: CGRect?
    ) throws -> [String: Any] {
        let context = CoordinateSupport.context(explicitScreen: coordinateSpace == .screen, relative: false)
        let snapshot = try plan(target: target, context: context)
        // A window's current snapshot owns its geometry; caller-provided pre-snapshot bounds may be stale.
        let report = target == .frontmostWindow ? snapshot.reportedBounds : reportedBounds ?? snapshot.reportedBounds
        let compatible = ScreenshotCapturePlan(requestedTarget: snapshot.requestedTarget, target: snapshot.target,
            windowID: snapshot.windowID, screenBounds: snapshot.screenBounds, reportedBounds: report,
            primaryBounds: snapshot.primaryBounds, coordinateSpace: snapshot.coordinateSpace,
            coordinateFallback: coordinateFallback || snapshot.coordinateFallback, relative: false)
        return try capture(plan: compatible, path: path)
    }

    static func capture(
        plan: ScreenshotCapturePlan, path: String, markerPoint: CGPoint? = nil,
        environment: ScreenshotCaptureEnvironment = ScreenshotCaptureEnvironment()
    ) throws -> [String: Any] {
        let url = try validateOutputPath(path)
        try environment.requirePermission()
        try ensureDirectory(for: url)
        // The staging directory is unique AND on the destination filesystem for atomic rename.
        let staging = url.deletingLastPathComponent().appendingPathComponent(".macos-cua-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let imageURL = staging.appendingPathComponent("capture.png")
        let result: Result<[String: Any], Error>
        do {
            try environment.runCapture(plan.arguments(outputPath: imageURL.path))
            let source = try pngDimensions(at: imageURL)
            try normalizeToActionSpaceIfNeeded(at: imageURL, bounds: plan.screenBounds)
            if let markerPoint { try annotatePostCrop(at: imageURL, markerPoint: markerPoint) }
            let dimensions = try pngDimensions(at: imageURL)
            var payload: [String: Any] = [
                "path": url.path,
                "requestedTarget": targetName(plan.requestedTarget),
                "target": targetName(plan.target),
                "bounds": CoordinateSupport.rectJSON(plan.reportedBounds),
                "screenBounds": CoordinateSupport.rectJSON(plan.screenBounds),
                "coordinateSpace": plan.coordinateSpace.rawValue,
                "coordinateFallback": plan.coordinateFallback,
                "coordinateUnits": "logical-points",
                "imageUnits": "pixels",
                "pixelsPerCoordinateUnit": 1,
                "content": plan.content,
                "captureMethod": plan.captureMethod,
                "windowID": plan.windowID as Any,
                "image": ["width": dimensions.width, "height": dimensions.height],
                "sourceImage": ["width": source.width, "height": source.height],
                // Measured source-pixel/logical-point ratios, not a claim of uniform physical display DPI.
                "normalizationScale": ["x": Double(source.width) / Double(dimensions.width),
                                       "y": Double(source.height) / Double(dimensions.height)],
                "actionSpace": CoordinateSupport.rectJSON(plan.primaryBounds),
            ]
            if plan.relative { payload["relative"] = true }
            guard Darwin.rename(imageURL.path, url.path) == 0 else {
                throw CUAError(message: "failed to publish screenshot: \(String(cString: strerror(errno)))")
            }
            result = .success(payload)
        } catch {
            result = .failure(error)
        }
        do { try FileManager.default.removeItem(at: staging) }
        catch {
            let outcome: String
            switch result {
            case .success: outcome = "screenshot was published"
            case .failure(let failure): outcome = "capture failed: \(failure.localizedDescription)"
            }
            throw CUAError(message: "\(outcome); staging cleanup failed: \(error.localizedDescription)")
        }
        return try result.get()
    }

    static func runCapture(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        do { try process.run() }
        catch { throw CUAError(message: "failed to launch screencapture: \(error.localizedDescription)") }
        // Drain before waiting, so a full stderr pipe cannot deadlock the child.
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CUAError(message: message.isEmpty ? "screencapture failed" : message)
        }
    }

    static func targetName(_ target: ScreenshotTarget) -> String {
        switch target {
        case .frontmostWindow: return "frontmost-window"
        case .screen: return "screen"
        case .region: return "region"
        }
    }

    static func bounds(for target: ScreenshotTarget) -> CGRect? {
        switch target {
        case .frontmostWindow:
            return WindowSupport.frontmostWindow()?.bounds ?? screenBounds()
        case .screen:
            return screenBounds()
        case .region(let rect):
            return rect
        }
    }

    static func screenBounds() -> CGRect? {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CoordinateSupport.isValidRectGeometry(bounds) ? bounds : nil
    }

    static func displayBounds() -> [CGRect] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }
    }

    static func cropRect(centeredAt point: CGPoint, within bounds: CGRect, size: CGFloat = 100) -> CGRect? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let half = size / 2
        let desired = CGRect(x: point.x - half, y: point.y - half, width: size, height: size)
        let clipped = desired.intersection(bounds.integral)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        return clipped
    }

    static func pngDimensions(at url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) == "public.png" as CFString,
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw CUAError(message: "failed to read screenshot dimensions: \(url.path)")
        }
        return (image.width, image.height)
    }

    static func normalizeToActionSpaceIfNeeded(at url: URL, target: ScreenshotTarget) throws {
        let context = CoordinateSupport.context(explicitScreen: target == .screen, relative: false)
        try normalizeToActionSpaceIfNeeded(at: url, bounds: plan(target: target, context: context).screenBounds)
    }

    static func normalizeToActionSpaceIfNeeded(at url: URL, bounds: CGRect) throws {
        try CoordinateSupport.validateRectGeometry(bounds)
        let targetWidth = Int(bounds.width.rounded())
        let targetHeight = Int(bounds.height.rounded())
        guard targetWidth > 0, targetHeight > 0 else { return }

        let current = try pngDimensions(at: url)
        guard current.width != targetWidth || current.height != targetHeight else { return }

        guard let source = NSImage(contentsOf: url) else {
            throw CUAError(message: "failed to load screenshot for action-space normalization: \(url.path)")
        }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw CUAError(message: "failed to allocate action-space normalized screenshot buffer: \(url.path)")
        }

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw CUAError(message: "failed to create action-space normalized screenshot context: \(url.path)")
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw CUAError(message: "failed to encode action-space normalized screenshot: \(url.path)")
        }

        try pngData.write(to: url, options: .atomic)
    }

    static func annotatePostCrop(at url: URL, markerPoint: CGPoint) throws {
        guard let source = NSImage(contentsOf: url) else {
            throw CUAError(message: "failed to load post-crop image for annotation: \(url.path)")
        }

        let dimensions = try pngDimensions(at: url)
        let targetWidth = dimensions.width
        let targetHeight = dimensions.height

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw CUAError(message: "failed to allocate post-crop annotation buffer: \(url.path)")
        }

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw CUAError(message: "failed to create post-crop annotation context: \(url.path)")
        }

        let clampedX = min(max(markerPoint.x, 0), CGFloat(targetWidth))
        let clampedY = min(max(markerPoint.y, 0), CGFloat(targetHeight))
        let drawPoint = CGPoint(x: clampedX, y: CGFloat(targetHeight) - clampedY)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSGraphicsContext.current?.imageInterpolation = .high

        source.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )

        drawTargetMarker(at: drawPoint)

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw CUAError(message: "failed to encode annotated post-crop image: \(url.path)")
        }

        try pngData.write(to: url, options: .atomic)
    }

    private static func drawTargetMarker(at point: CGPoint) {
        let outerRadius: CGFloat = 18
        let innerRadius: CGFloat = 8
        let crossRadius: CGFloat = 24
        let dotRadius: CGFloat = 4

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = .zero
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()

        NSColor.white.withAlphaComponent(0.95).setStroke()
        let outer = NSBezierPath(ovalIn: CGRect(
            x: point.x - outerRadius,
            y: point.y - outerRadius,
            width: outerRadius * 2,
            height: outerRadius * 2
        ))
        outer.lineWidth = 4
        outer.stroke()

        NSColor.systemPink.withAlphaComponent(0.95).setStroke()
        let inner = NSBezierPath(ovalIn: CGRect(
            x: point.x - innerRadius,
            y: point.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        ))
        inner.lineWidth = 4
        inner.stroke()

        let vertical = NSBezierPath()
        vertical.move(to: CGPoint(x: point.x, y: point.y - crossRadius))
        vertical.line(to: CGPoint(x: point.x, y: point.y + crossRadius))
        vertical.lineWidth = 3
        vertical.stroke()

        let horizontal = NSBezierPath()
        horizontal.move(to: CGPoint(x: point.x - crossRadius, y: point.y))
        horizontal.line(to: CGPoint(x: point.x + crossRadius, y: point.y))
        horizontal.lineWidth = 3
        horizontal.stroke()

        NSColor.systemCyan.withAlphaComponent(0.95).setFill()
        let centerDot = NSBezierPath(ovalIn: CGRect(
            x: point.x - dotRadius,
            y: point.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        ))
        centerDot.fill()

        NSGraphicsContext.restoreGraphicsState()
    }
}
