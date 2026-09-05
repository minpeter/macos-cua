import AppKit
import CoreGraphics
import Foundation
import ImageIO

enum ScreenshotTarget: Equatable {
    case frontmostWindow
    case screen
    case region(CGRect)
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

    static func capture(
        target: ScreenshotTarget,
        path: String,
        coordinateSpace: CoordinateSpaceName,
        coordinateFallback: Bool,
        reportedBounds: CGRect?
    ) throws -> [String: Any] {
        try PermissionSupport.require(.screenRecording, for: "screenshots")
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.lowercased().hasSuffix(".png") else {
            throw CUAError(message: "screenshot currently requires a .png output path")
        }
        try ensureDirectory(for: url)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments(for: target, outputPath: url.path)
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CUAError(message: "failed to launch screencapture: \(error.localizedDescription)")
        }
        if process.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CUAError(message: message?.isEmpty == false ? message! : "screencapture failed")
        }

        try normalizeToActionSpaceIfNeeded(at: url, target: target)
        let dimensions = try pngDimensions(at: url)
        let actionSpace = try InputSupport.actionSpace()
        return [
            "path": url.path,
            "target": targetName(target),
            "bounds": reportedBounds.map(CoordinateSupport.rectJSON) as Any,
            "coordinateSpace": coordinateSpace.rawValue,
            "coordinateFallback": coordinateFallback,
            "image": [
                "width": dimensions.width,
                "height": dimensions.height,
            ],
            "actionSpace": actionSpace,
        ]
    }

    static func arguments(for target: ScreenshotTarget, outputPath: String) -> [String] {
        switch target {
        case .frontmostWindow:
            if let window = WindowSupport.frontmostWindow() {
                if let id = window.id {
                    return ["-x", "-o", "-l", String(id), outputPath]
                }
                let region = "\(Int(window.bounds.origin.x.rounded())),\(Int(window.bounds.origin.y.rounded())),\(Int(window.bounds.size.width.rounded())),\(Int(window.bounds.size.height.rounded()))"
                return ["-x", "-R\(region)", outputPath]
            }
            return ["-x", "-m", outputPath]
        case .screen:
            return ["-x", "-m", outputPath]
        case .region(let rect):
            let region = "\(Int(rect.origin.x.rounded())),\(Int(rect.origin.y.rounded())),\(Int(rect.size.width.rounded())),\(Int(rect.size.height.rounded()))"
            return ["-x", "-R\(region)", outputPath]
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
            return WindowSupport.frontmostWindow()?.bounds
        case .screen:
            return screenBounds()
        case .region(let rect):
            return rect
        }
    }

    static func screenBounds() -> CGRect? {
        guard let screen = NSScreen.main else { return nil }
        return CGRect(origin: .zero, size: screen.frame.size)
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
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw CUAError(message: "failed to read screenshot dimensions: \(url.path)")
        }
        return (width, height)
    }

    static func normalizeToActionSpaceIfNeeded(at url: URL, target: ScreenshotTarget) throws {
        guard let bounds = bounds(for: target) else { return }

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

        let size = source.size
        let targetWidth = Int(size.width.rounded())
        let targetHeight = Int(size.height.rounded())
        guard targetWidth > 0, targetHeight > 0 else { return }

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
