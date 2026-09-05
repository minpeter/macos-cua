import ApplicationServices
import CoreGraphics
import XCTest
@testable import macos_cua

final class WindowIdentityRegressionTests: XCTestCase {
    func testEqualAXReferencesAreDeduplicatedByNativeIdentity() {
        let first = AXUIElementCreateApplication(12345)
        let second = AXUIElementCreateApplication(12345)
        XCTAssertTrue(CFEqual(first, second))
        XCTAssertEqual(WindowSupport.deduplicatedAXWindows([first, second]).count, 1)
    }

    func testFloatingInspectorDoesNotImplyBlockingModal() {
        XCTAssertFalse(modalState(subrole: "AXFloatingWindow", modal: nil).blockingModalPresent)
        XCTAssertTrue(modalState(subrole: "AXFloatingWindow", modal: true).blockingModalPresent)
        XCTAssertFalse(modalState(subrole: "AXDialog", modal: false).blockingModalPresent)
    }

    func testNativeIDsDisambiguateIdenticalTitlesAndBounds() {
        let windows = records([snapshot(1, id: 20), snapshot(2, id: 10)], cg: [makeWindow(id: 10), makeWindow(id: 20)])
        XCTAssertEqual(windows.map(\.id), [10, 20])
        XCTAssertEqual(Set(windows.compactMap(\.id)).count, windows.count)
    }

    func testMissingNativeIdentityNeverBorrowsSingleOrMatchingCGWindow() throws {
        let windows = records([snapshot(1, id: nil), snapshot(2, id: nil)], cg: [makeWindow(id: 10)])
        XCTAssertEqual(windows.count, 2)
        XCTAssertTrue(windows.allSatisfy { $0.id == nil && !$0.onScreen && !$0.isFrontmost })
        let data = try JSONSerialization.data(withJSONObject: windows.map(\.json))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertTrue(json.allSatisfy { $0["id"] is NSNull })
    }

    func testDuplicateNativeClaimsInvalidateBothInsteadOfKeepingFirst() {
        for snapshots in [[snapshot(1, id: 10), snapshot(2, id: 10)], [snapshot(2, id: 10), snapshot(1, id: 10)]] {
            let windows = records(snapshots, cg: [makeWindow(id: 10)])
            XCTAssertEqual(windows.count, 2)
            XCTAssertTrue(windows.allSatisfy { $0.id == nil })
        }
    }

    func testRepeatedAXReferenceIsOneWindowNotConflictingClaims() {
        let windows = records([snapshot(1, id: 10), snapshot(1, id: 10)], cg: [makeWindow(id: 10)])
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.id, 10)
    }

    func testOffscreenAndMinimizedUseCGVisibilityAndRemainListed() {
        let windows = records([
            snapshot(1, id: 10), snapshot(2, id: 20), snapshot(3, id: 30, minimized: true),
            snapshot(4, id: 40, minimized: true)
        ], cg: [makeWindow(id: 10), makeWindow(id: 20, onScreen: false), makeWindow(id: 30)])
        XCTAssertEqual(windows.map(\.id), [10, 20, 30, 40])
        XCTAssertEqual(windows.map(\.onScreen), [true, false, false, false])
        XCTAssertEqual(windows.map(\.isMinimized), [false, false, true, true])
        XCTAssertEqual(windows[2].json["minimized"] as? Bool, true)
    }

    func testHiddenToolsAndChildrenExcludedButSmallStandardWindowsRemain() {
        let small = CGRect(x: 0, y: 0, width: 30, height: 20)
        let windows = records([
            snapshot(1, id: 10, bounds: small), snapshot(2, id: 20, hidden: true),
            snapshot(3, id: 30, subrole: "AXFloatingWindow"),
            snapshot(4, id: 40, parentRole: "AXWindow"),
            snapshot(5, id: 50, role: "AXButton"), snapshot(6, id: 60, subrole: "AXDialog")
        ], cg: [])
        XCTAssertEqual(windows.map(\.id), [10, 60])
        XCTAssertTrue(WindowSupport.records(from: [snapshot(1, id: 10)], pid: 12345,
                                           appName: "Fixture", appHidden: true, cgWindows: []).isEmpty)
    }

    func testOrderingIsFrontmostThenAppTitleIDAndIndependentOfEnumeration() {
        let input = [makeWindow(id: 30, app: "Zulu"), makeWindow(id: 20), makeWindow(id: 10),
                     makeWindow(id: nil), makeWindow(id: 40, app: "Zulu", frontmost: true)]
        for order in [input, Array(input.reversed()), [input[2], input[4], input[0], input[3], input[1]]] {
            XCTAssertEqual(WindowSupport.sortedWindows(order).map(\.id), [40, 10, 20, nil, 30])
        }
    }

    func testMissingIDsAreNeverEqualIdentityOrAutomaticallyFrontmost() {
        let windows = records([snapshot(1, id: nil), snapshot(2, id: nil, focused: true)], cg: [])
        XCTAssertEqual(windows.filter(\.isFrontmost).count, 1)
        XCTAssertNil(WindowSupport.exactWindowIndex(id: nil, nativeIDs: [nil, nil]))
        XCTAssertNil(WindowSupport.exactWindowIndex(id: 10, nativeIDs: [10, 10]))
        XCTAssertEqual(WindowSupport.exactWindowIndex(id: 20, nativeIDs: [10, nil, 20]), 2)
    }

    func testActivationRequiresObservedExactVisibleFrontmostIdentity() throws {
        let target = makeWindow(id: 10)
        for observed in [nil, makeWindow(id: 20, frontmost: true), makeWindow(id: nil, frontmost: true),
                         makeWindow(id: 10), makeWindow(id: 10, onScreen: false, frontmost: true),
                         makeWindow(id: 10, pid: 54321, frontmost: true)] as [WindowRecord?] {
            XCTAssertThrowsError(try WindowSupport.activationPayload(target: target, observed: observed))
        }
        XCTAssertThrowsError(try WindowSupport.activationPayload(target: makeWindow(id: nil), observed: makeWindow(id: nil, frontmost: true)))
        let payload = try WindowSupport.activationPayload(target: target, observed: makeWindow(id: 10, frontmost: true))
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["targetId"] as? Int, 10)
        XCTAssertEqual((payload["window"] as? [String: Any])?["id"] as? Int, 10)
    }

    func testConfirmationSubscribesBeforeActionAndCleansUpOnSuccess() throws {
        var subscribed = false
        var cleanedUp = false
        var selected = false
        var signal: (() -> Void)?
        let confirmed = try AppSupport.confirmActivation(subscribe: { observation in
            subscribed = true
            signal = { observation.check() }
            return { cleanedUp = true; signal = nil }
        }, action: {
            XCTAssertTrue(subscribed)
            selected = true
            try XCTUnwrap(signal)()
        }, verify: { selected })
        XCTAssertTrue(confirmed)
        XCTAssertTrue(cleanedUp)
    }

    func testConfirmationRequestAcceptanceAloneIsNotSuccess() {
        var cleanedUp = false
        let confirmed = AppSupport.confirmActivation(timeout: 0, subscribe: { observation in
            observation.check()
            return { cleanedUp = true }
        }, action: {}, verify: { false })
        XCTAssertFalse(confirmed)
        XCTAssertTrue(cleanedUp)
    }

    func testConfirmationCleansUpWhenActionFails() {
        var cleanedUp = false
        XCTAssertThrowsError(try AppSupport.confirmActivation(subscribe: { _ in
            return { cleanedUp = true }
        }, action: { throw CUAError(message: "fixture") }, verify: { false }))
        XCTAssertTrue(cleanedUp)
    }

    func testWindowIDsUseFullUInt32RangeAndRejectInvalidValues() throws {
        for id in [Int(Int32.max) + 1, Int(UInt32.max)] {
            XCTAssertEqual(WindowSupport.exactWindowIndex(id: id, nativeIDs: [id]), 0)
            let payload = try WindowSupport.activationPayload(target: makeWindow(id: id), observed: makeWindow(id: id, frontmost: true))
            XCTAssertEqual(payload["targetId"] as? Int, id)
        }
        for id in [-1, 0, Int(UInt32.max) + 1, Int.max] {
            XCTAssertNil(WindowSupport.exactWindowIndex(id: id, nativeIDs: [id]))
            XCTAssertThrowsError(try WindowSupport.activationPayload(target: makeWindow(id: id), observed: makeWindow(id: id, frontmost: true)))
        }
    }

    func testConflictingCGOwnerCannotAssociateIdentity() {
        let windows = records([snapshot(1, id: 10)], cg: [makeWindow(id: 10, pid: 54321)])
        XCTAssertNil(windows.first?.id)
        XCTAssertEqual(windows.first?.onScreen, false)
    }

    func testConfirmationWaitsForSubscribedNativeNotificationWithoutPolling() {
        let center = NotificationCenter()
        let name = Notification.Name("WindowIdentityRegressionSelection")
        var selected = false
        var delivered = false
        let port = Port()
        RunLoop.current.add(port, forMode: .default)
        defer { RunLoop.current.remove(port, forMode: .default); port.invalidate() }
        let confirmed = AppSupport.confirmActivation(subscribe: { observation in
            center.addObserver(observation, selector: #selector(AppSupport.ActivationConfirmation.notified(_:)), name: name, object: nil)
            return { center.removeObserver(observation) }
        }, action: {
            CFRunLoopPerformBlock(CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue) {
                selected = true
                delivered = true
                center.post(name: name, object: nil)
            }
        }, verify: { selected })
        XCTAssertTrue(delivered)
        XCTAssertTrue(confirmed)
    }

    private func modalState(subrole: String, modal: Bool?) -> WindowSupport.BlockingModalState {
        WindowSupport.blockingModalState(
            focused: WindowSupport.WindowDescriptor(record: makeWindow(id: 20), role: "AXWindow", subrole: subrole, isModal: modal),
            main: WindowSupport.WindowDescriptor(record: makeWindow(id: 10), role: "AXWindow", subrole: "AXStandardWindow"),
            focusedElement: AXUIElementCreateApplication(12345), mainElement: AXUIElementCreateApplication(54321)
        )
    }

    private func snapshot(_ identity: Int32, id: Int?, bounds: CGRect = CGRect(x: 10, y: 20, width: 400, height: 300),
                          minimized: Bool = false, hidden: Bool = false, role: String = "AXWindow",
                          subrole: String = "AXStandardWindow", parentRole: String = "AXApplication", focused: Bool = false) -> WindowSupport.AXWindowSnapshot {
        WindowSupport.AXWindowSnapshot(element: AXUIElementCreateApplication(identity), nativeID: id,
                                       title: "Duplicate", bounds: bounds, role: role, subrole: subrole,
                                       parentRole: parentRole, minimized: minimized, hidden: hidden, focused: focused)
    }

    private func records(_ snapshots: [WindowSupport.AXWindowSnapshot], cg: [WindowRecord]) -> [WindowRecord] {
        WindowSupport.records(from: snapshots, pid: 12345, appName: "Fixture", appHidden: false, cgWindows: cg)
    }

    private func makeWindow(id: Int?, pid: Int32 = 12345, app: String = "Fixture", onScreen: Bool = true, frontmost: Bool = false) -> WindowRecord {
        WindowRecord(id: id, pid: pid, appName: app, title: "Duplicate",
                     bounds: CGRect(x: 10, y: 20, width: 400, height: 300),
                     layer: 0, onScreen: onScreen, isFrontmost: frontmost)
    }
}
