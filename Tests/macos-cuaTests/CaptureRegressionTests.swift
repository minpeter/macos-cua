import AppKit
import CoreGraphics
import XCTest
@testable import macos_cua

final class CaptureRegressionTests: XCTestCase {
    func testNoWindowScreenshotReportsPrimaryBounds() {
        let context = CoordinateSupport.context(explicitScreen: false, relative: false, frontmostWindow: nil)
        XCTAssertNotNil(ScreenshotSupport.screenBounds())
        XCTAssertEqual(context.screenshotReportedBounds(for: .frontmostWindow), ScreenshotSupport.screenBounds())
    }

    func testRejectsEmptyAndOutOfExtentRegions() {
        let context = CoordinateSupport.context(explicitScreen: false, relative: false,
            frontmostWindow: window(CGRect(x: 10, y: 20, width: 500, height: 400)))
        for rect in [CGRect(x: 0, y: 0, width: 0, height: 20),
                     CGRect(x: -1, y: 0, width: 20, height: 20),
                     CGRect(x: 490, y: 0, width: 20, height: 20)] {
            XCTAssertThrowsError(try context.inputRect(rect))
        }
        let relative = CoordinateSupport.context(explicitScreen: false, relative: true,
            frontmostWindow: window(CGRect(x: 10, y: 20, width: 500, height: 400)))
        XCTAssertThrowsError(try relative.inputRect(CGRect(x: 0, y: 0, width: 0, height: 1000)))
    }

    func testRejectsWindowPointOutsideEveryMonitor() {
        let context = CoordinateSupport.context(explicitScreen: false, relative: false,
            frontmostWindow: window(CGRect(x: 1_000_000, y: 1_000_000, width: 500, height: 400)))
        XCTAssertThrowsError(try context.inputPoint(x: 10, y: 20))
    }

    func testUnusableWindowFallsBackToPrimary() {
        let context = CoordinateSupport.context(explicitScreen: false, relative: false,
            frontmostWindow: window(.zero))
        XCTAssertEqual(context.coordinateSpace, .screen)
        XCTAssertTrue(context.coordinateFallback)
    }

    func testScreenPointsStayInPrimaryExtentAndWindowPointsRejectMonitorGaps() throws {
        let primary = CGRect(x: 0, y: 0, width: 100, height: 80)
        let displays = [primary, CGRect(x: 200, y: 20, width: 100, height: 80),
                        CGRect(x: -100, y: -80, width: 100, height: 80)]
        let context = CoordinateSupport.context(explicitScreen: true, relative: false,
            frontmostWindow: nil, primaryBounds: primary, displayBounds: displays)
        XCTAssertThrowsError(try context.inputPoint(x: 200, y: 20))
        XCTAssertThrowsError(try context.inputPoint(x: -1, y: -1))
        let spanning = CoordinateSupport.context(explicitScreen: false, relative: false,
            frontmostWindow: window(CGRect(x: 0, y: 0, width: 300, height: 100)),
            primaryBounds: primary, displayBounds: displays)
        XCTAssertEqual(try spanning.inputPoint(x: 200, y: 20).screen, CGPoint(x: 200, y: 20))
        XCTAssertThrowsError(try spanning.inputPoint(x: 150, y: 40))
        XCTAssertThrowsError(try spanning.inputPoint(x: 200, y: 0))
        for point in [(100, 0), (150, 40), (200, 0), (300, 20), (0, 80)] {
            XCTAssertThrowsError(try context.inputPoint(x: point.0, y: point.1))
        }
        let relative = CoordinateSupport.context(explicitScreen: true, relative: true,
            frontmostWindow: nil, primaryBounds: primary, displayBounds: displays)
        XCTAssertEqual(try relative.inputPoint(x: 1000, y: 1000).screen, CGPoint(x: 99, y: 79))
    }

    func testPartiallyOffscreenWindowRejectsUnreachableLocalPoint() throws {
        let primary = CGRect(x: 0, y: 0, width: 100, height: 80)
        let context = CoordinateSupport.context(explicitScreen: false, relative: false,
            frontmostWindow: window(CGRect(x: -20, y: 0, width: 100, height: 80)),
            primaryBounds: primary, displayBounds: [primary])
        XCTAssertThrowsError(try context.inputPoint(x: 0, y: 0))
        XCTAssertEqual(try context.inputPoint(x: 20, y: 0).screen, .zero)
    }

    func testLocalAndRelativeRegionsTranslateAndReportOnce() throws {
        let primary = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let record = window(CGRect(x: 120, y: 80, width: 500, height: 400))
        let context = CoordinateSupport.context(explicitScreen: false, relative: false,
            frontmostWindow: record, primaryBounds: primary, displayBounds: [primary])
        let rect = try context.inputRect(CGRect(x: 10, y: 20, width: 100, height: 80))
        XCTAssertEqual(rect.screen, CGRect(x: 130, y: 100, width: 100, height: 80))
        let plan = try ScreenshotSupport.plan(target: .region(rect.screen), context: context)
        XCTAssertEqual(plan.reportedBounds, rect.local)
        XCTAssertEqual(plan.arguments(outputPath: "/tmp/fixture.png"),
            ["-x", "-t", "png", "-R130,100,100,80", "/tmp/fixture.png"])
        let relative = CoordinateSupport.context(explicitScreen: false, relative: true,
            frontmostWindow: record, primaryBounds: primary, displayBounds: [primary])
        let full = try relative.inputRect(CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(full.screen, record.bounds)
        XCTAssertEqual(try ScreenshotSupport.plan(target: .region(full.screen), context: relative).reportedBounds,
            CGRect(x: 0, y: 0, width: 1000, height: 1000))
    }

    func testInvalidNonfiniteAndNegativeRegionsThrowWithoutIntegerTraps() {
        let context = fixtureContext()
        for rect in [CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
                     CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10),
                     CGRect(x: 0, y: 0, width: -1, height: 10)] {
            XCTAssertThrowsError(try context.inputRect(rect))
            XCTAssertThrowsError(try CoordinateSupport.validateRelativeRect(rect))
            XCTAssertThrowsError(try ScreenshotSupport.plan(target: .region(rect), context: context))
        }
    }

    func testCapturePlanFreezesWindowIdentityBoundsAndContent() throws {
        var record = window(CGRect(x: 10, y: 20, width: 50, height: 40))
        let context = CoordinateSupport.context(explicitScreen: false, relative: false,
            frontmostWindow: record, primaryBounds: CGRect(x: 0, y: 0, width: 100, height: 80),
            displayBounds: [CGRect(x: 0, y: 0, width: 100, height: 80)])
        let plan = try ScreenshotSupport.plan(target: .frontmostWindow, context: context)
        record = window(CGRect(x: 100, y: 100, width: 900, height: 700), id: 99)
        XCTAssertEqual(record.id, 99)
        XCTAssertEqual(plan.windowID, 42)
        XCTAssertEqual(plan.screenBounds, CGRect(x: 10, y: 20, width: 50, height: 40))
        XCTAssertEqual(plan.reportedBounds, CGRect(x: 0, y: 0, width: 50, height: 40))
        XCTAssertEqual(plan.content, "window-surface")
        XCTAssertEqual(plan.arguments(outputPath: "/tmp/frozen.png"),
            ["-x", "-t", "png", "-o", "-l", "42", "/tmp/frozen.png"])
    }

    func testNoNativeWindowIDUsesVisibleDesktopRegion() throws {
        let primary = CGRect(x: 0, y: 0, width: 100, height: 80)
        let context = CoordinateSupport.context(explicitScreen: false, relative: false,
            frontmostWindow: window(CGRect(x: 10, y: 20, width: 50, height: 40), id: nil),
            primaryBounds: primary, displayBounds: [primary])
        let plan = try ScreenshotSupport.plan(target: .frontmostWindow, context: context)
        XCTAssertNil(plan.windowID)
        XCTAssertEqual(plan.content, "visible-desktop")
        XCTAssertEqual(plan.arguments(outputPath: "/tmp/region.png"),
            ["-x", "-t", "png", "-R10,20,50,40", "/tmp/region.png"])
    }

    func testFallbackNormalizesRetinaImageAndReportsTruthfulMetadata() throws {
        let directory = try temporaryDirectory()
        defer { removeFixture(directory) }
        let destination = directory.appendingPathComponent("new/retina.PNG")
        let plan = try ScreenshotSupport.plan(target: .frontmostWindow, context: fixtureContext())
        var environment = ScreenshotCaptureEnvironment()
        environment.requirePermission = {}
        environment.runCapture = { arguments in
            XCTAssertEqual(Array(arguments.dropLast()), ["-x", "-t", "png", "-m"])
            try Self.png(width: 200, height: 160).write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
        }
        let result = try ScreenshotSupport.capture(plan: plan, path: destination.path, environment: environment)
        let dimensions = try ScreenshotSupport.pngDimensions(at: destination)
        XCTAssertEqual(dimensions.width, 100)
        XCTAssertEqual(dimensions.height, 80)
        XCTAssertEqual(result["target"] as? String, "screen")
        XCTAssertEqual(result["requestedTarget"] as? String, "frontmost-window")
        XCTAssertEqual(result["coordinateSpace"] as? String, "screen")
        XCTAssertEqual(result["coordinateFallback"] as? Bool, true)
        XCTAssertEqual(result["content"] as? String, "visible-desktop")
        XCTAssertEqual(result["coordinateUnits"] as? String, "logical-points")
        XCTAssertEqual(result["pixelsPerCoordinateUnit"] as? Int, 1)
        XCTAssertEqual((result["sourceImage"] as? [String: Int])?["width"], 200)
        XCTAssertEqual((result["normalizationScale"] as? [String: Double])?["x"], 2)
        XCTAssertEqual((result["bounds"] as? [String: Int])?["width"], 100)
        XCTAssertEqual((result["actionSpace"] as? [String: Int])?["width"], 100)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: result))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["retina.PNG"])
    }

    func testInvalidPathIsRejectedBeforePermissionOrAcquisition() throws {
        let plan = try ScreenshotSupport.plan(target: .screen, context: fixtureContext())
        var environment = ScreenshotCaptureEnvironment()
        environment.requirePermission = { XCTFail("permission called for invalid path") }
        environment.runCapture = { _ in XCTFail("capture called for invalid path") }
        for path in ["/tmp/image.jpg", "/tmp/image.png/", "/tmp/image.png.txt"] {
            XCTAssertThrowsError(try ScreenshotSupport.capture(plan: plan, path: path, environment: environment))
        }
    }

    func testFailedAcquisitionAndCorruptPNGPreserveExistingDestination() throws {
        let directory = try temporaryDirectory()
        defer { removeFixture(directory) }
        let destination = directory.appendingPathComponent("result.png")
        let previous = try Self.png(width: 100, height: 80)
        try previous.write(to: destination)
        let plan = try ScreenshotSupport.plan(target: .screen, context: fixtureContext())
        for acquisitionFailure in [true, false] {
            var environment = ScreenshotCaptureEnvironment()
            environment.requirePermission = {}
            environment.runCapture = { arguments in
                try Data("partial output".utf8).write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
                if acquisitionFailure { throw CUAError(message: "fixture acquisition failed") }
            }
            XCTAssertThrowsError(try ScreenshotSupport.capture(plan: plan, path: destination.path, environment: environment))
            XCTAssertEqual(try Data(contentsOf: destination), previous)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["result.png"])
        }
    }

    func testOverlappingCapturesHaveUniqueStagingAndAtomicLastPublication() throws {
        let directory = try temporaryDirectory()
        defer { removeFixture(directory) }
        let destination = directory.appendingPathComponent("result.png")
        let old = try Self.png(width: 100, height: 80, red: 0)
        let first = try Self.png(width: 100, height: 80, red: 80)
        let second = try Self.png(width: 100, height: 80, red: 200)
        try old.write(to: destination)
        let plan = try ScreenshotSupport.plan(target: .screen, context: fixtureContext())
        var outer = ScreenshotCaptureEnvironment()
        outer.requirePermission = {}
        outer.runCapture = { arguments in
            let outerStage = URL(fileURLWithPath: try XCTUnwrap(arguments.last))
            XCTAssertNotEqual(outerStage, destination)
            try Data("incomplete".utf8).write(to: outerStage)
            XCTAssertEqual(try Data(contentsOf: destination), old)
            var inner = ScreenshotCaptureEnvironment()
            inner.requirePermission = {}
            inner.runCapture = { arguments in
                let innerStage = URL(fileURLWithPath: try XCTUnwrap(arguments.last))
                XCTAssertNotEqual(innerStage, outerStage)
                XCTAssertEqual(innerStage.deletingLastPathComponent().deletingLastPathComponent(), directory)
                try second.write(to: innerStage)
                XCTAssertEqual(try Data(contentsOf: destination), old)
            }
            _ = try ScreenshotSupport.capture(plan: plan, path: destination.path, environment: inner)
            XCTAssertEqual(try Data(contentsOf: destination), second)
            try first.write(to: outerStage)
            XCTAssertEqual(try Data(contentsOf: destination), second)
        }
        _ = try ScreenshotSupport.capture(plan: plan, path: destination.path, environment: outer)
        XCTAssertEqual(try Data(contentsOf: destination), first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["result.png"])
    }

    func testNativeConcurrentWritersPublishWholePNG() throws {
        let directory = try temporaryDirectory()
        defer { removeFixture(directory) }
        let destination = directory.appendingPathComponent("result.png")
        let images = try [Self.png(width: 100, height: 80, red: 50), Self.png(width: 100, height: 80, red: 200)]
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                let primary = CGRect(x: 0, y: 0, width: 100, height: 80)
                let context = CoordinateSupport.context(explicitScreen: true, relative: false,
                    frontmostWindow: nil, primaryBounds: primary, displayBounds: [primary])
                let plan = try ScreenshotSupport.plan(target: .screen, context: context)
                var environment = ScreenshotCaptureEnvironment()
                environment.requirePermission = {}
                environment.runCapture = { arguments in
                    try images[index].write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
                }
                _ = try ScreenshotSupport.capture(plan: plan, path: destination.path, environment: environment)
            } catch { XCTFail("concurrent capture failed: \(error)") }
        }
        XCTAssertTrue(images.contains(try Data(contentsOf: destination)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["result.png"])
    }

    func testAnnotationUsesPixelDimensionsNotPNGResolutionMetadata() throws {
        let directory = try temporaryDirectory()
        defer { removeFixture(directory) }
        let destination = directory.appendingPathComponent("annotated.png")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: Self.png(width: 100, height: 80)))
        rep.size = NSSize(width: 50, height: 40)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: destination)
        try ScreenshotSupport.annotatePostCrop(at: destination, markerPoint: CGPoint(x: 50, y: 40))
        XCTAssertEqual(try ScreenshotSupport.pngDimensions(at: destination).width, 100)
        XCTAssertEqual(try ScreenshotSupport.pngDimensions(at: destination).height, 80)
    }

    private func fixtureContext() -> CoordinateContext {
        let primary = CGRect(x: 0, y: 0, width: 100, height: 80)
        return CoordinateSupport.context(explicitScreen: false, relative: false,
            frontmostWindow: nil, primaryBounds: primary, displayBounds: [primary])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-regression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func removeFixture(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { XCTFail("fixture cleanup failed: \(error)") }
    }

    private static func png(width: Int, height: Int, red: UInt8 = 128) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
            pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(rep.bitmapData)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rep.bytesPerRow + x * 4
                pixels[offset] = red
                pixels[offset + 1] = UInt8(x % 256)
                pixels[offset + 2] = UInt8(y % 256)
                pixels[offset + 3] = 255
            }
        }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func window(_ bounds: CGRect, id: Int? = 42) -> WindowRecord {
        WindowRecord(id: id, pid: 123, appName: "CaptureFixture", title: "fixture",
            bounds: bounds, layer: 0, onScreen: true, isFrontmost: true)
    }
}
