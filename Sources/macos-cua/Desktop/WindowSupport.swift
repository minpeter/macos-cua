import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Darwin

enum WindowSupport {
    static let duplicateTitleHint = "Duplicate window titles detected; use screen-space to bring the target window frontmost first."
    static let modalWindowRoles: Set<String> = [
        "AXSheet",
        "AXDrawer",
    ]
    static let modalWindowSubroles: Set<String> = [
        "AXDialog",
        "AXFloatingWindow",
        "AXSystemDialog",
    ]
    static let blockingModalReason = "A modal dialog is currently focused. Handle it before interacting with the main window."

    struct WindowDescriptor {
        let record: WindowRecord
        let role: String?
        let subrole: String?
        var isModal: Bool? = nil

        var json: [String: Any] {
            var payload = record.json
            payload["role"] = role as Any
            payload["subrole"] = subrole as Any
            payload["modal"] = isModal.map { $0 as Any } ?? NSNull()
            return payload
        }
    }

    struct BlockingModalState {
        let focusedWindow: WindowDescriptor?
        let mainWindow: WindowDescriptor?
        let blockingModalWindow: WindowDescriptor?

        var blockingModalPresent: Bool { blockingModalWindow != nil }
        var interactionBlocked: Bool { blockingModalPresent }

        var payload: [String: Any] {
            var payload: [String: Any] = [
                "blockingModalPresent": blockingModalPresent,
                "interactionBlocked": interactionBlocked,
            ]
            if let blockingModalWindow {
                payload["blockingModalWindow"] = blockingModalWindow.json
                payload["requiredAction"] = "dismiss-or-handle-modal"
                payload["allowedTargets"] = ["modal", "system-dialog"]
                payload["blockedTargets"] = ["main-window"]
                payload["blockingReason"] = blockingModalReason
            }
            if let mainWindow {
                payload["mainWindow"] = mainWindow.json
            }
            return payload
        }

        var line: String? {
            guard let blockingModalWindow else { return nil }
            let title = blockingModalWindow.record.title.isEmpty ? "<untitled>" : blockingModalWindow.record.title
            let role = blockingModalWindow.role ?? "AXWindow"
            let subroleSuffix = blockingModalWindow.subrole.map { "/\($0)" } ?? ""
            return "Blocking modal: \(title) [\(role)\(subroleSuffix)]"
        }
    }

    static func isAccessibilityTrusted() -> Bool {
        PermissionSupport.isGranted(.accessibility)
    }

    static func axAppElement(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    static func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        axValue(element, attribute) as? String
    }

    static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = axValue(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        axValue(element, attribute) as? Bool
    }

    static func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = axValue(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    static func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = axValue(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    static func axWindows(for app: NSRunningApplication) -> [AXUIElement] {
        guard isAccessibilityTrusted() else { return [] }
        return (axValue(axAppElement(pid: app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    static func cgWindowInfoList(onScreenOnly: Bool) -> [[String: Any]] {
        let options: CGWindowListOption = onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll, .excludeDesktopElements]
        let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as NSArray? as? [[String: Any]]
        return raw ?? []
    }

    static func bounds(from info: [String: Any]) -> CGRect? {
        guard let dictionary = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    static func interactiveWindows(onScreenOnly: Bool = true) -> [WindowRecord] {
        cgWindowInfoList(onScreenOnly: onScreenOnly).compactMap { info in
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            guard layer == 0, alpha > 0 else { return nil }
            guard let bounds = bounds(from: info), bounds.width > 1, bounds.height > 1 else { return nil }
            let pid = Int32(info[kCGWindowOwnerPID as String] as? Int ?? 0)
            let appName = info[kCGWindowOwnerName as String] as? String ?? "Unknown"
            let title = info[kCGWindowName as String] as? String ?? ""
            let id = info[kCGWindowNumber as String] as? Int
            return WindowRecord(
                id: id,
                pid: pid,
                appName: appName,
                title: title,
                bounds: bounds,
                layer: layer,
                onScreen: (info[kCGWindowIsOnscreen as String] as? Int ?? 0) != 0,
                isFrontmost: false
            )
        }
    }

    static func cgWindowCandidates(pid: pid_t) -> [WindowRecord] {
        // The all-windows snapshot includes minimized windows even when the same app
        // also owns visible windows. CG ordering must not influence AX identity.
        interactiveWindows(onScreenOnly: false).filter { $0.pid == pid }
    }

    typealias AXWindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    // macOS exposes no public AX-to-CG identity API. Resolve the native bridge at
    // runtime so its absence is a nullable ID, not a launch/link failure or a guess.
    static let axWindowIDFunction: AXWindowIDFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: AXWindowIDFunction.self)
    }()

    static func nativeWindowID(_ window: AXUIElement) -> Int? {
        guard let getWindow = axWindowIDFunction else { return nil }
        var id: CGWindowID = 0
        guard getWindow(window, &id) == .success, id != kCGNullWindowID else { return nil }
        return Int(id)
    }

    struct AXWindowSnapshot {
        let element: AXUIElement
        let nativeID: Int?
        let title: String
        let bounds: CGRect
        let role: String?
        let subrole: String?
        let parentRole: String?
        let minimized: Bool
        let hidden: Bool
        let focused: Bool

        var isInteractiveTopLevel: Bool {
            role == "AXWindow"
                && (subrole == nil || ["AXStandardWindow", "AXDialog", "AXSystemDialog"].contains(subrole!))
                && (parentRole == nil || parentRole == "AXApplication")
                && bounds.width > 1 && bounds.height > 1 && !hidden
        }
    }

    static func snapshot(for window: AXUIElement, focused: AXUIElement?) -> AXWindowSnapshot? {
        guard let position = axPoint(window, kAXPositionAttribute),
              let size = axSize(window, kAXSizeAttribute), size.width > 1, size.height > 1 else { return nil }
        return AXWindowSnapshot(
            element: window, nativeID: nativeWindowID(window),
            title: axString(window, kAXTitleAttribute) ?? "", bounds: CGRect(origin: position, size: size),
            role: axString(window, kAXRoleAttribute), subrole: axString(window, kAXSubroleAttribute),
            parentRole: axElement(window, kAXParentAttribute).flatMap { axString($0, kAXRoleAttribute) },
            minimized: axBool(window, kAXMinimizedAttribute) == true,
            hidden: axBool(window, "AXHidden") == true, focused: sameAXElement(window, focused)
        )
    }

    static func exactWindowIndex(id: Int?, nativeIDs: [Int?]) -> Int? {
        guard let id, id > 0, UInt32(exactly: id) != nil else { return nil }
        let matches = nativeIDs.indices.filter { nativeIDs[$0] == id }
        return matches.count == 1 ? matches[0] : nil
    }

    static func record(from snapshot: AXWindowSnapshot, id: Int?, pid: pid_t,
                       appName: String, appHidden: Bool, cgWindows: [WindowRecord]) -> WindowRecord {
        // AX and CG are separate snapshots; a reused ID owned by another process
        // is contradictory evidence, not permission to associate that window.
        let id = id.flatMap { candidate in
            cgWindows.contains { $0.id == candidate && $0.pid != pid } ? nil : candidate
        }
        let cg = id.flatMap { id in cgWindows.first { $0.id == id && $0.pid == pid } }
        return WindowRecord(
            id: id, pid: pid, appName: appName, title: snapshot.title.isEmpty ? (cg?.title ?? "") : snapshot.title,
            bounds: snapshot.bounds, layer: cg?.layer ?? 0,
            onScreen: cg?.onScreen == true && !snapshot.minimized && !snapshot.hidden && !appHidden,
            isFrontmost: snapshot.focused && !snapshot.minimized && !snapshot.hidden && !appHidden,
            isMinimized: snapshot.minimized
        )
    }

    static func records(from snapshots: [AXWindowSnapshot], pid: pid_t, appName: String,
                        appHidden: Bool, cgWindows: [WindowRecord]) -> [WindowRecord] {
        guard !appHidden else { return [] }
        var unique: [AXWindowSnapshot] = []
        for snapshot in snapshots where !unique.contains(where: { sameAXElement($0.element, snapshot.element) }) {
            unique.append(snapshot)
        }
        let ids = unique.map(\.nativeID)
        return sortedWindows(unique.filter(\.isInteractiveTopLevel).map { snapshot in
            let id = exactWindowIndex(id: snapshot.nativeID, nativeIDs: ids) == nil ? nil : snapshot.nativeID
            return record(from: snapshot, id: id, pid: pid, appName: appName, appHidden: appHidden, cgWindows: cgWindows)
        })
    }

    static func record(for window: AXUIElement, app: NSRunningApplication, cgFallback: WindowRecord? = nil) -> WindowRecord? {
        let focused = app.processIdentifier == AppSupport.frontmostApplication()?.processIdentifier
            ? axElement(axAppElement(pid: app.processIdentifier), kAXFocusedWindowAttribute) : nil
        guard let snapshot = snapshot(for: window, focused: focused) else { return nil }
        let windows = deduplicatedAXWindows(axWindows(for: app) + [window])
        let id = exactWindowIndex(id: snapshot.nativeID, nativeIDs: windows.map(nativeWindowID)) == nil ? nil : snapshot.nativeID
        return record(from: snapshot, id: id, pid: app.processIdentifier, appName: app.localizedName ?? "Unknown",
                      appHidden: app.isHidden, cgWindows: cgWindowCandidates(pid: app.processIdentifier))
    }

    static func descriptor(for window: AXUIElement, app: NSRunningApplication, cgFallback: WindowRecord? = nil) -> WindowDescriptor? {
        guard let record = record(for: window, app: app, cgFallback: cgFallback) else {
            return nil
        }
        return WindowDescriptor(
            record: record,
            role: axString(window, kAXRoleAttribute),
            subrole: axString(window, kAXSubroleAttribute),
            isModal: axBool(window, kAXModalAttribute)
        )
    }

    static func isModalLikeWindow(role: String?, subrole: String?) -> Bool {
        role.map(modalWindowRoles.contains) == true || subrole.map(modalWindowSubroles.contains) == true
    }

    static func shouldAssociateFallbackWindowID(title: String, bounds: CGRect, fallback: WindowRecord?) -> Bool {
        guard let fallback else { return false }
        let sameTitle = !title.isEmpty && title == fallback.title
        let closeOrigin = abs(bounds.origin.x - fallback.bounds.origin.x) < 12
            && abs(bounds.origin.y - fallback.bounds.origin.y) < 12
        let closeSize = abs(bounds.width - fallback.bounds.width) < 12
            && abs(bounds.height - fallback.bounds.height) < 12
        return sameTitle || (closeOrigin && closeSize)
    }

    static func sameAXElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else { return false }
        return CFEqual(lhs, rhs)
    }

    static func blockingModalState(
        focused: WindowDescriptor?,
        main: WindowDescriptor?,
        focusedElement: AXUIElement?,
        mainElement: AXUIElement?
    ) -> BlockingModalState {
        let focusedDiffersFromMain = focusedElement != nil && mainElement != nil && !sameAXElement(focusedElement, mainElement)
        let blockingModalWindow: WindowDescriptor?
        if let focused,
           focusedDiffersFromMain,
           focused.isModal ?? (focused.role == "AXSheet" || focused.subrole == "AXDialog" || focused.subrole == "AXSystemDialog") {
            blockingModalWindow = focused
        } else {
            blockingModalWindow = nil
        }
        return BlockingModalState(
            focusedWindow: focused,
            mainWindow: main,
            blockingModalWindow: blockingModalWindow
        )
    }

    static func currentBlockingModalState() -> BlockingModalState {
        guard isAccessibilityTrusted(),
              let app = AppSupport.frontmostApplication() else {
            return BlockingModalState(focusedWindow: nil, mainWindow: nil, blockingModalWindow: nil)
        }

        let cgFallback = interactiveWindows().first(where: { $0.pid == app.processIdentifier })
        let appElement = axAppElement(pid: app.processIdentifier)
        let focusedElement = axElement(appElement, kAXFocusedWindowAttribute)
        let mainElement = axElement(appElement, kAXMainWindowAttribute)
        let focused = focusedElement.flatMap { descriptor(for: $0, app: app, cgFallback: cgFallback) }
        let main = mainElement.flatMap { descriptor(for: $0, app: app, cgFallback: cgFallback) }
        return blockingModalState(
            focused: focused,
            main: main,
            focusedElement: focusedElement,
            mainElement: mainElement
        )
    }

    static func deduplicatedAXWindows(_ windows: [AXUIElement]) -> [AXUIElement] {
        var deduped: [AXUIElement] = []
        for window in windows where !deduped.contains(where: { sameAXElement($0, window) }) {
            deduped.append(window)
        }
        return deduped
    }

    static func frontmostAXWindowElement(for app: NSRunningApplication, cgFallback: WindowRecord?) -> AXUIElement? {
        guard isAccessibilityTrusted(), !app.isHidden else { return nil }
        let appElement = axAppElement(pid: app.processIdentifier)
        // Focus is direct AX identity. Never override it with title/geometry ranking.
        if let focused = axElement(appElement, kAXFocusedWindowAttribute),
           axBool(focused, kAXMinimizedAttribute) != true,
           axBool(focused, "AXHidden") != true {
            return focused
        }
        let windows = deduplicatedAXWindows(axWindows(for: app)).filter {
            axBool($0, kAXMinimizedAttribute) != true && axBool($0, "AXHidden") != true
        }
        guard let index = exactWindowIndex(id: cgFallback?.id, nativeIDs: windows.map(nativeWindowID)) else { return nil }
        return windows[index]
    }

    static func frontmostWindow() -> WindowRecord? {
        guard let app = AppSupport.frontmostApplication() else { return nil }

        let cgFallback = interactiveWindows().first(where: { $0.pid == app.processIdentifier })

        guard isAccessibilityTrusted() else {
            if let record = cgFallback {
                return WindowRecord(id: record.id, pid: record.pid, appName: record.appName, title: record.title, bounds: record.bounds, layer: record.layer, onScreen: record.onScreen, isFrontmost: true)
            }
            return nil
        }

        guard let axWindow = frontmostAXWindowElement(for: app, cgFallback: cgFallback) else {
            if let record = cgFallback {
                return WindowRecord(id: record.id, pid: record.pid, appName: record.appName, title: record.title, bounds: record.bounds, layer: record.layer, onScreen: record.onScreen, isFrontmost: true)
            }
            return nil
        }
        guard let record = record(for: axWindow, app: app, cgFallback: cgFallback), record.onScreen else { return nil }
        return record
    }

    static func matchWindowID(pid: pid_t, title: String, bounds: CGRect) -> Int? {
        // Kept for source compatibility. These values cannot prove native identity,
        // even when CG currently reports only one candidate. Use nativeWindowID.
        nil
    }

    static func frontmostWindowAXElement() -> AXUIElement? {
        guard let app = AppSupport.frontmostApplication() else { return nil }
        let cgFallback = interactiveWindows().first(where: { $0.pid == app.processIdentifier })
        return frontmostAXWindowElement(for: app, cgFallback: cgFallback)
    }

    static func sortedWindows(_ windows: [WindowRecord]) -> [WindowRecord] {
        windows.sorted { lhs, rhs in
            if lhs.isFrontmost != rhs.isFrontmost { return lhs.isFrontmost }
            if lhs.appName.lowercased() != rhs.appName.lowercased() { return lhs.appName.lowercased() < rhs.appName.lowercased() }
            if lhs.title.lowercased() != rhs.title.lowercased() { return lhs.title.lowercased() < rhs.title.lowercased() }
            if lhs.id != rhs.id {
                guard let left = lhs.id else { return false }
                guard let right = rhs.id else { return true }
                return left < right
            }
            if lhs.appName != rhs.appName { return lhs.appName < rhs.appName }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
            let left = [lhs.bounds.minX, lhs.bounds.minY, lhs.bounds.width, lhs.bounds.height]
            let right = [rhs.bounds.minX, rhs.bounds.minY, rhs.bounds.width, rhs.bounds.height]
            return left.lexicographicallyPrecedes(right)
        }
    }

    static func listWindows() -> [WindowRecord] {
        let apps = AppSupport.runningUserApplications().filter { !$0.isHidden }
        let frontmostPID = AppSupport.frontmostApplication()?.processIdentifier
        let cgWindows = interactiveWindows(onScreenOnly: false)
        if isAccessibilityTrusted() {
            let records = apps.flatMap { app -> [WindowRecord] in
                let focused = app.processIdentifier == frontmostPID
                    ? axElement(axAppElement(pid: app.processIdentifier), kAXFocusedWindowAttribute) : nil
                let snapshots = deduplicatedAXWindows(axWindows(for: app)).compactMap { snapshot(for: $0, focused: focused) }
                return self.records(from: snapshots, pid: app.processIdentifier, appName: app.localizedName ?? "Unknown",
                                    appHidden: app.isHidden, cgWindows: cgWindows)
            }
            // An authoritative AX empty list must not reintroduce filtered tool windows.
            return sortedWindows(records)
        }
        let userPIDs = Set(apps.map(\.processIdentifier))
        let frontmostID = cgWindows.first { $0.pid == frontmostPID && $0.onScreen }?.id
        return sortedWindows(cgWindows.filter { userPIDs.contains($0.pid) }.map { record in
            WindowRecord(id: record.id, pid: record.pid, appName: record.appName, title: record.title,
                         bounds: record.bounds, layer: record.layer, onScreen: record.onScreen,
                         isFrontmost: record.id != nil && record.id == frontmostID && record.pid == frontmostPID)
        })
    }

    static func hasDuplicateTitle(_ target: WindowRecord, in windows: [WindowRecord]? = nil) -> Bool {
        let candidates = (windows ?? listWindows()).filter { $0.pid == target.pid && $0.title == target.title }
        return candidates.count > 1
    }

    static func duplicateTitleWindows(in windows: [WindowRecord]) -> [WindowRecord] {
        var counts: [String: Int] = [:]
        for window in windows {
            counts["\(window.pid)|\(window.title)"] = (counts["\(window.pid)|\(window.title)"] ?? 0) + 1
        }
        return windows.filter { (counts["\($0.pid)|\($0.title)"] ?? 0) > 1 }
    }

    static func window(byID id: Int) -> WindowRecord? {
        listWindows().first(where: { $0.id == id })
    }

    static func resolveTargetWindow(id: Int?) throws -> WindowRecord {
        if let id {
            guard let target = window(byID: id) else {
                throw CUAError(message: "window not found: \(id)")
            }
            return target
        }
        guard let frontmost = frontmostWindow() else {
            throw CUAError(message: "no frontmost window is available")
        }
        return frontmost
    }

    static func runningApplication(pid: pid_t) -> NSRunningApplication? {
        AppSupport.runningUserApplications().first(where: { $0.processIdentifier == pid })
    }

    static func windowPayload(for target: WindowRecord) -> [String: Any]? {
        if let id = target.id, let refreshed = window(byID: id) {
            return refreshed.json
        }
        if let app = runningApplication(pid: target.pid),
           let axWindow = axWindowElement(for: target, includeMinimized: true),
           let refreshed = record(for: axWindow, app: app) {
            return refreshed.json
        }
        return nil
    }

    static func axWindowElement(for target: WindowRecord, includeMinimized: Bool = false) -> AXUIElement? {
        guard isAccessibilityTrusted(), let app = runningApplication(pid: target.pid) else { return nil }
        let windows = deduplicatedAXWindows(axWindows(for: app))
        guard let index = exactWindowIndex(id: target.id, nativeIDs: windows.map(nativeWindowID)) else { return nil }
        let window = windows[index]
        guard includeMinimized || axBool(window, kAXMinimizedAttribute) != true else { return nil }
        return window
    }

    static func isExactActivation(target: WindowRecord, observed: WindowRecord?) -> Bool {
        guard let id = target.id, id > 0, UInt32(exactly: id) != nil, let observed else { return false }
        return observed.id == id && observed.pid == target.pid && observed.isFrontmost
            && observed.onScreen && observed.isMinimized != true
    }

    static func activationPayload(target: WindowRecord, observed: WindowRecord?) throws -> [String: Any] {
        guard isExactActivation(target: target, observed: observed), let observed, let id = target.id else {
            throw CUAError(message: "failed to confirm exact activated window: \(target.id.map(String.init) ?? "unknown")")
        }
        return ["ok": true, "targetId": id, "window": observed.json]
    }

    static func activateWindow(id: Int) throws -> [String: Any] {
        guard id > 0, UInt32(exactly: id) != nil else {
            throw CUAError(message: "window id must be in 1...4294967295")
        }
        let target = try resolveTargetWindow(id: id)
        guard let app = runningApplication(pid: target.pid) else {
            throw CUAError(message: "window app is no longer running: \(id)")
        }
        // Resolve exact identity before any activation/unminimize side effect.
        guard let window = axWindowElement(for: target, includeMinimized: true) else {
            throw CUAError(message: "exact AX window identity is unavailable for \(id)")
        }
        let appElement = axAppElement(pid: target.pid)
        var observed: WindowRecord?
        let confirmed = try AppSupport.confirmActivation(subscribe: { observation in
            var observer: AXObserver?
            let status = AXObserverCreate(target.pid, { _, _, _, context in
                guard let context else { return }
                Unmanaged<AppSupport.ActivationConfirmation>.fromOpaque(context).takeUnretainedValue().check()
            }, &observer)
            guard status == .success, let observer else {
                throw CUAError(message: "failed to observe window activation: AX error \(status.rawValue)")
            }
            let notifications: [(AXUIElement, String)] = [
                (appElement, kAXFocusedWindowChangedNotification),
                (appElement, kAXMainWindowChangedNotification),
                (window, kAXWindowDeminiaturizedNotification),
            ]
            let context = Unmanaged.passUnretained(observation).toOpaque()
            var registered: [(AXUIElement, String)] = []
            for (element, notification) in notifications {
                let result = AXObserverAddNotification(observer, element, notification as CFString, context)
                if result == .success {
                    registered.append((element, notification))
                } else if result != .notificationUnsupported {
                    for (element, notification) in registered {
                        AXObserverRemoveNotification(observer, element, notification as CFString)
                    }
                    throw CUAError(message: "failed to subscribe to window activation: AX error \(result.rawValue)")
                }
            }
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopAddSource(observation.runLoop, source, .defaultMode)
            let center = NSWorkspace.shared.notificationCenter
            center.addObserver(observation, selector: #selector(AppSupport.ActivationConfirmation.notified(_:)),
                               name: NSWorkspace.didActivateApplicationNotification, object: nil)
            return {
                center.removeObserver(observation)
                CFRunLoopRemoveSource(observation.runLoop, source, .defaultMode)
                for (element, notification) in registered {
                    AXObserverRemoveNotification(observer, element, notification as CFString)
                }
            }
        }, action: {
            guard nativeWindowID(window) == id else {
                throw CUAError(message: "window identity changed before activation: \(id)")
            }
            app.unhide()
            _ = app.activate()
            if axBool(window, kAXMinimizedAttribute) == true {
                let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                guard result == .success else {
                    throw CUAError(message: "failed to unminimize window \(id): AX error \(result.rawValue)")
                }
            }
            let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            guard result == .success else {
                throw CUAError(message: "failed to raise window \(id): AX error \(result.rawValue)")
            }
        }, verify: {
            guard AppSupport.frontmostApplication()?.processIdentifier == target.pid,
                  let focused = axElement(appElement, kAXFocusedWindowAttribute), sameAXElement(focused, window),
                  nativeWindowID(focused) == id else { return false }
            observed = record(for: focused, app: app)
            return isExactActivation(target: target, observed: observed)
        })
        guard confirmed else { throw CUAError(message: "failed to confirm exact activated window: \(id)") }
        return try activationPayload(target: target, observed: observed)
    }

}
