import CoreGraphics
import XCTest
@testable import macos_cua

final class CoordinateSupportTests: XCTestCase {
    func testResolveDefaultsToWindowWhenFrontmostWindowExists() {
        let window = makeWindow(bounds: CGRect(x: 120, y: 80, width: 900, height: 700))
        let context = CoordinateSupport.context(explicitScreen: false, relative: false, frontmostWindow: window)

        XCTAssertEqual(context.coordinateSpace, .window)
        XCTAssertFalse(context.coordinateFallback)
        XCTAssertEqual(context.windowBounds?.origin.x, 120)
        XCTAssertEqual(context.windowBounds?.origin.y, 80)
    }

    func testResolveFallsBackToScreenWhenWindowIsMissing() {
        let context = CoordinateSupport.context(explicitScreen: false, relative: false, frontmostWindow: nil)

        XCTAssertEqual(context.coordinateSpace, .screen)
        XCTAssertTrue(context.coordinateFallback)
        XCTAssertNil(context.windowBounds)
    }

    func testExplicitScreenBypassesWindowOffset() throws {
        let window = makeWindow(bounds: CGRect(x: 400, y: 300, width: 800, height: 600))
        let context = CoordinateSupport.context(explicitScreen: true, relative: false, frontmostWindow: window)
        let actionPoint = try context.inputPoint(x: 25, y: 40)

        XCTAssertEqual(actionPoint.local.x, 25, accuracy: 0.0001)
        XCTAssertEqual(actionPoint.local.y, 40, accuracy: 0.0001)
        XCTAssertEqual(actionPoint.screen.x, 25, accuracy: 0.0001)
        XCTAssertEqual(actionPoint.screen.y, 40, accuracy: 0.0001)
        XCTAssertFalse(context.coordinateFallback)
    }

    func testWindowTranslationMapsLocalPointIntoScreenSpace() throws {
        let window = makeWindow(bounds: CGRect(x: 300, y: 180, width: 640, height: 480))
        let context = CoordinateSupport.context(explicitScreen: false, relative: false, frontmostWindow: window)
        let translated = try context.inputPoint(x: 17, y: 23)

        XCTAssertEqual(translated.screen.x, 317, accuracy: 0.0001)
        XCTAssertEqual(translated.screen.y, 203, accuracy: 0.0001)
    }

    func testWindowPointRejectsNegativeCoordinates() {
        let window = makeWindow(bounds: CGRect(x: 300, y: 180, width: 640, height: 480))
        let context = CoordinateSupport.context(explicitScreen: false, relative: false, frontmostWindow: window)

        XCTAssertThrowsError(try context.inputPoint(x: -1, y: 0))
    }

    func testWindowPointRejectsCoordinatesOutsideWindow() {
        let window = makeWindow(bounds: CGRect(x: 300, y: 180, width: 640, height: 480))
        let context = CoordinateSupport.context(explicitScreen: false, relative: false, frontmostWindow: window)

        XCTAssertThrowsError(try context.inputPoint(x: 640, y: 480))
    }

    func testLocalPointerSubtractsWindowOrigin() {
        let window = makeWindow(bounds: CGRect(x: 220, y: 140, width: 900, height: 700))
        let context = CoordinateSupport.context(explicitScreen: false, relative: false, frontmostWindow: window)
        let pointer = context.pointerWindowPoint(fromScreenPoint: CGPoint(x: 260, y: 175))

        XCTAssertNotNil(pointer)
        XCTAssertEqual(pointer?.x ?? .nan, 40, accuracy: 0.0001)
        XCTAssertEqual(pointer?.y ?? .nan, 35, accuracy: 0.0001)
    }

    func testFrontmostWindowScreenshotBoundsUseLocalOrigin() {
        let window = makeWindow(bounds: CGRect(x: 10, y: 20, width: 500, height: 400))
        let context = CoordinateSupport.context(explicitScreen: false, relative: false, frontmostWindow: window)
        let bounds = context.screenshotReportedBounds(for: .frontmostWindow)

        XCTAssertNotNil(bounds)
        XCTAssertEqual(bounds?.origin.x ?? .nan, 0, accuracy: 0.0001)
        XCTAssertEqual(bounds?.origin.y ?? .nan, 0, accuracy: 0.0001)
        XCTAssertEqual(bounds?.size.width ?? .nan, 500, accuracy: 0.0001)
        XCTAssertEqual(bounds?.size.height ?? .nan, 400, accuracy: 0.0001)
    }

    func testWindowRegionScreenshotBoundsStayLocal() {
        let window = makeWindow(bounds: CGRect(x: 10, y: 20, width: 500, height: 400))
        let context = CoordinateSupport.context(explicitScreen: false, relative: false, frontmostWindow: window)
        let region = CGRect(x: 30, y: 40, width: 120, height: 80)
        let bounds = context.screenshotReportedBounds(for: .region(region))

        XCTAssertNotNil(bounds)
        XCTAssertEqual(bounds?.origin.x ?? .nan, 30, accuracy: 0.0001)
        XCTAssertEqual(bounds?.origin.y ?? .nan, 40, accuracy: 0.0001)
        XCTAssertEqual(bounds?.size.width ?? .nan, 120, accuracy: 0.0001)
        XCTAssertEqual(bounds?.size.height ?? .nan, 80, accuracy: 0.0001)
    }

    func testRelativePointMapsCenterOfWindow() throws {
        let window = makeWindow(bounds: CGRect(x: 100, y: 50, width: 800, height: 600))
        let context = CoordinateSupport.context(explicitScreen: false, relative: true, frontmostWindow: window)
        let point = try context.inputPoint(x: 500, y: 500)

        XCTAssertEqual(point.local.x, 399.5, accuracy: 0.0001)
        XCTAssertEqual(point.local.y, 299.5, accuracy: 0.0001)
        XCTAssertEqual(point.screen.x, 499.5, accuracy: 0.0001)
        XCTAssertEqual(point.screen.y, 349.5, accuracy: 0.0001)
    }

    func testRelativeOutputRectNormalizesWindowBounds() {
        let window = makeWindow(bounds: CGRect(x: 10, y: 20, width: 500, height: 400))
        let context = CoordinateSupport.context(explicitScreen: false, relative: true, frontmostWindow: window)
        let rect = context.screenshotReportedBounds(for: .frontmostWindow)

        XCTAssertNotNil(rect)
        XCTAssertEqual(rect?.origin.x ?? .nan, 0, accuracy: 0.0001)
        XCTAssertEqual(rect?.origin.y ?? .nan, 0, accuracy: 0.0001)
        XCTAssertEqual(rect?.width ?? .nan, 1000, accuracy: 0.0001)
        XCTAssertEqual(rect?.height ?? .nan, 1000, accuracy: 0.0001)
    }

    private func makeWindow(bounds: CGRect) -> WindowRecord {
        WindowRecord(
            id: 99,
            pid: 123,
            appName: "TestApp",
            title: "Test Window",
            bounds: bounds,
            layer: 0,
            onScreen: true,
            isFrontmost: true
        )
    }
}
