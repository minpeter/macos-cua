import AppKit
import CoreGraphics
import XCTest
@testable import macos_cua

final class InputRegressionTests: XCTestCase {
    func testEmptyKeypressRejected() {
        for combo in ["", "+", "++"] {
            XCTAssertThrowsError(try InputSupport.keypress(combo), combo)
        }
    }

    func testInvalidKeypressPostsNoEvents() {
        for combo in ["cmd+not-a-key", "cmd+a+b", "cmd++a", "+a", "a+"] {
            var events: [CGEvent] = []
            XCTAssertThrowsError(try InputSupport.keypress(combo) { event in
                events.append(try XCTUnwrap(event))
            }, combo)
            XCTAssertTrue(events.isEmpty, combo)
        }
    }

    func testCRLFNormalizesLikeLF() throws {
        var decoded = ""
        try InputSupport.typeText("a\r\nb", fast: true, pause: { _ in }, postEvent: { event in
            let event = try XCTUnwrap(event)
            if event.type == .keyDown {
                decoded += try XCTUnwrap(NSEvent(cgEvent: event)?.characters)
            }
        })
        XCTAssertEqual(decoded, "a\nb")
    }

    func testASCIIUsesBoundedBatches() throws {
        var events: [CGEvent] = []
        try InputSupport.typeText(String(repeating: "a", count: 41), fast: true, pause: { _ in }, postEvent: { event in
            events.append(try XCTUnwrap(event))
        })
        XCTAssertEqual(events.filter { $0.type == .keyDown }.count, 3)
    }

    func testTextBudgetAndBatchBoundaries() throws {
        for fast in [false, true] {
            var delay: UInt64 = 0
            var count = 0
            try InputSupport.typeText(String(repeating: "a", count: 8192), fast: fast,
                pause: { delay += UInt64($0) }, postEvent: { _ in count += 1 })
            XCTAssertLessThan(delay, 20_000_000)
            XCTAssertLessThanOrEqual(count, 2050)
        }
    }

    func testUnicodeAndNewlineEquivalence() throws {
        var decoded = ""
        try InputSupport.typeText("한글 😀\r\nline\nfin", fast: true, pause: { _ in },
            postEvent: { event in
                let event = try XCTUnwrap(event)
                if event.type == .keyDown && event.flags.isEmpty {
                    decoded += try XCTUnwrap(NSEvent(cgEvent: event)?.characters)
                }
            })
        XCTAssertEqual(decoded, "한글 😀\nline\nfin")
    }

    func testTextPreservesRichClipboardAndExternalWrites() throws {
        for externalWrite in [false, true] {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let item = NSPasteboardItem()
            let rich = Data("{\\rtf1 original}".utf8)
            XCTAssertTrue(item.setString("original", forType: .string))
            XCTAssertTrue(item.setData(rich, forType: .rtf))
            XCTAssertTrue(board.writeObjects([item]))
            let originalCount = board.changeCount
            var posted = false
            try InputSupport.typeText("한글 😀", fast: true, pause: { _ in },
                postEvent: { _ in
                    if externalWrite && !posted {
                        board.clearContents()
                        XCTAssertTrue(board.setString("external", forType: .string))
                    }
                    posted = true
                })
            XCTAssertTrue(posted)
            if externalWrite {
                XCTAssertEqual(board.string(forType: .string), "external")
            } else {
                XCTAssertEqual(board.data(forType: .rtf), rich)
                XCTAssertEqual(board.changeCount, originalCount)
            }
        }
    }

    func testLargeNativeClipboardRoundTrip() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let text = String(repeating: "한글 😀\n", count: 350_000)
        try ClipboardSupport.setText(text, pasteboard: board)
        let count = board.changeCount
        XCTAssertEqual(try ClipboardSupport.getText(pasteboard: board), text)
        XCTAssertEqual(board.changeCount, count)
    }

    func testClickRejectsObservedPointerMismatch() throws {
        var posted = 0
        var moved = false
        XCTAssertThrowsError(try InputSupport.click(point: CGPoint(x: 40, y: 50), button: .left,
            count: 1, profile: .fast,
            move: { _, _, _, _ in
                moved = true
                return PointerMotionPlan(samples: [], interClickDelayMicros: nil)
            }, pointer: { CGPoint(x: 39, y: 50) }, postEvent: { _ in posted += 1 }))
        XCTAssertTrue(moved)
        XCTAssertEqual(posted, 0)
    }

    func testPrimaryActionSpaceAndPointer() throws {
        let sample = try XCTUnwrap(CGEvent(source: nil))
        sample.location = CGPoint(x: -1234.75, y: 678.25)
        XCTAssertEqual(InputSupport.currentPointer(event: sample), sample.location)
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let space = try InputSupport.actionSpace()
        XCTAssertEqual(space["width"] as? Int, Int(bounds.width.rounded()))
        XCTAssertEqual(space["height"] as? Int, Int(bounds.height.rounded()))
    }
    func testScrollRejectsOutOfRangeBeforePosting() {
        for invalid in [Int(Int32.max) + 1, Int(Int32.min) - 1, Int.max, Int.min] {
            for delta in [(invalid, 0), (0, invalid)] {
                var posted = false
                XCTAssertThrowsError(try InputSupport.scroll(dx: delta.0, dy: delta.1,
                    postEvent: { _ in posted = true }))
                XCTAssertFalse(posted)
            }
        }
    }

    func testScrollKeepsNativePixelDirectionAndGranularity() throws {
        for delta in [(13, -27), (-13, 27), (0, 0)] {
            var events: [CGEvent] = []
            try InputSupport.scroll(dx: delta.0, dy: delta.1,
                postEvent: { events.append(try XCTUnwrap($0)) })
            let event = try XCTUnwrap(events.first)
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(event.type, .scrollWheel)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), Int64(delta.1))
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), Int64(delta.0))
            let native = try XCTUnwrap(NSEvent(cgEvent: event))
            XCTAssertTrue(native.hasPreciseScrollingDeltas)
            XCTAssertEqual(native.scrollingDeltaX, CGFloat(delta.0))
            XCTAssertEqual(native.scrollingDeltaY, CGFloat(delta.1))
        }
    }

    func testValidKeypressBalancesModifiers() throws {
        var events: [CGEvent] = []
        try InputSupport.keypress("CMD+shift+a", postEvent: { events.append(try XCTUnwrap($0)) })
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [55, 56, 0, 0, 56, 55])
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
        let combined: CGEventFlags = [.maskCommand, .maskShift]
        XCTAssertEqual(events.map(\.flags), [.maskCommand, combined, combined, combined, .maskCommand, []])
        events.removeAll()
        try InputSupport.keypress("cmd", postEvent: { events.append(try XCTUnwrap($0)) })
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged])
        XCTAssertEqual(events.last?.flags, [])
    }

    func testTextUTF16ScalarBoundariesAndExactNativePayloads() throws {
        let texts = [
            String(repeating: "a", count: 19) + "😀한글 e\u{301}👩‍👩‍👧‍👦\tline\nfin",
            String(repeating: "x", count: 7) + "😀" + String(repeating: "\u{301}", count: 45),
            String(repeating: "😀", count: 4096),
        ]
        for fast in [false, true] {
            for text in texts {
                var decoded = ""
                var previous: [UniChar] = []
                var totalDelay: UInt64 = 0
                try InputSupport.typeText(text, fast: fast, pause: { totalDelay += UInt64($0) }, postEvent: { event in
                    let event = try XCTUnwrap(event)
                    var units = [UniChar](repeating: 0, count: 32)
                    var length = 0
                    event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
                    units = Array(units.prefix(length))
                    XCTAssertGreaterThan(length, 0)
                    XCTAssertLessThanOrEqual(length, 20)
                    XCTAssertFalse((0xDC00...0xDFFF).contains(try XCTUnwrap(units.first)))
                    XCTAssertFalse((0xD800...0xDBFF).contains(try XCTUnwrap(units.last)))
                    XCTAssertEqual(event.flags, [])
                    if event.type == .keyDown {
                        previous = units
                        decoded += try XCTUnwrap(NSEvent(cgEvent: event)?.characters)
                    } else {
                        XCTAssertEqual(event.type, .keyUp)
                        XCTAssertEqual(units, previous)
                    }
                })
                XCTAssertEqual(decoded, text)
                XCTAssertLessThan(totalDelay, 20_000_000)
            }
        }
    }

    func testTextEmptyAndOversizedHaveNoEffects() {
        for fast in [false, true] {
            var effects = 0
            XCTAssertNoThrow(try InputSupport.typeText("", fast: fast,
                pause: { _ in effects += 1 }, postEvent: { _ in effects += 1 }))
            for text in [String(repeating: "a", count: 8193), String(repeating: "😀", count: 4097)] {
                XCTAssertThrowsError(try InputSupport.typeText(text, fast: fast,
                    pause: { _ in effects += 1 }, postEvent: { _ in effects += 1 }))
            }
            XCTAssertEqual(effects, 0)
        }
    }

    func testClickWithMatchingObservedPointerBalancesButtons() throws {
        for button in [MouseButtonName.left, .right, .middle] {
            let point = CGPoint(x: 40, y: 50)
            var events: [CGEvent] = []
            var moved = false
            try InputSupport.click(point: point, button: button, count: 1, profile: .fast,
                move: { destination, profile, _, _ in
                    XCTAssertEqual(destination, point)
                    XCTAssertEqual(profile, .fast)
                    moved = true
                    return PointerMotionPlan(samples: [], interClickDelayMicros: nil)
                }, pointer: {
                    XCTAssertTrue(moved)
                    return point
                }, postEvent: { events.append(try XCTUnwrap($0)) })
            XCTAssertEqual(events.map(\.type), [button.downType, button.upType])
            XCTAssertEqual(events.map(\.location), [point, point])
            XCTAssertEqual(events.map { $0.getIntegerValueField(.mouseEventClickState) }, [1, 1])
        }
    }

    func testMouseDownRejectsNonfiniteAndHalfPointMismatch() {
        let point = CGPoint(x: 40, y: 50)
        for observed in [CGPoint(x: 40.5, y: 50), CGPoint(x: 40, y: 49.5),
                         CGPoint(x: CGFloat.nan, y: 50), CGPoint(x: 40, y: CGFloat.infinity)] {
            var posted = false
            XCTAssertThrowsError(try InputSupport.mouseDown(at: point, button: .left,
                pointer: { observed }, postEvent: { _ in posted = true }))
            XCTAssertFalse(posted)
        }
    }

    func testClipboardReadPreservesAllItemsAndFormats() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertEqual(try ClipboardSupport.getText(pasteboard: board), "")
        let first = NSPasteboardItem()
        let second = NSPasteboardItem()
        let rich = Data("{\\rtf1 text}".utf8)
        let custom = NSPasteboard.PasteboardType("org.macos-cua.input-test")
        XCTAssertTrue(first.setString("plain", forType: .string))
        XCTAssertTrue(first.setData(rich, forType: .rtf))
        XCTAssertTrue(second.setData(Data([0, 1, 255]), forType: custom))
        XCTAssertTrue(board.writeObjects([first, second]))
        let changeCount = board.changeCount
        XCTAssertEqual(try ClipboardSupport.getText(pasteboard: board), "plain")
        XCTAssertEqual(board.changeCount, changeCount)
        let items = try XCTUnwrap(board.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].data(forType: .rtf), rich)
        XCTAssertEqual(items[1].data(forType: custom), Data([0, 1, 255]))
    }
    func testMaximumTextCompletesWithinDeadline() throws {
        for fast in [false, true] {
            let started = ContinuousClock.now
            var units = 0
            try InputSupport.typeText(String(repeating: "a", count: 8192), fast: fast, postEvent: { event in
                let event = try XCTUnwrap(event)
                if event.type == .keyDown {
                    units += try XCTUnwrap(NSEvent(cgEvent: event)?.characters).utf16.count
                }
            })
            XCTAssertEqual(units, 8192)
            XCTAssertLessThan(started.duration(to: .now), .seconds(20))
        }
    }
}
