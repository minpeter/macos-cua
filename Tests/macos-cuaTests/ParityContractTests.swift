import XCTest
@testable import macos_cua

final class ParityContractTests: XCTestCase {
    func testScreenshotTargetParsesWindowAndScreen() throws {
        XCTAssertEqual(try ScreenshotSupport.target(named: "window"), .frontmostWindow)
        XCTAssertEqual(try ScreenshotSupport.target(named: "screen"), .screen)
    }

    func testScreenshotTargetRejectsUnknownValue() {
        XCTAssertThrowsError(try ScreenshotSupport.target(named: "desktop"))
    }

    func testUnicodeTextUsesClipboardPaste() {
        XCTAssertTrue(InputSupport.requiresClipboardPaste("한글 😀"))
        XCTAssertFalse(InputSupport.requiresClipboardPaste("ASCII\nLine2"))
    }

    func testTypeRejectsMoreThan8192UTF16Units() {
        XCTAssertThrowsError(
            try InputSupport.typeText(String(repeating: "a", count: 8_193), fast: true)
        )
    }
}
