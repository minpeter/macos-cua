import AppKit
import Foundation

enum AppSupport {
    static let launchTimeoutMs = 20_000
    static let launchPollIntervalMicros: useconds_t = 100_000

    static func appBundleName(_ app: NSRunningApplication) -> String? {
        app.bundleURL?.deletingPathExtension().lastPathComponent
    }

    static func runAppleScript(_ lines: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = lines.flatMap { ["-e", $0] }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func openApplication(query: String, activate: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if query.contains(".") {
            process.arguments = activate ? ["-b", query] : ["-g", "-b", query]
        } else {
            process.arguments = activate ? ["-a", query] : ["-g", "-a", query]
        }
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CUAError(message: "failed to launch app: \(error.localizedDescription)")
        }
        if process.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CUAError(message: message?.isEmpty == false ? message! : "failed to launch app: \(query)")
        }
    }

    static func runningUserApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular &&
                !app.isTerminated &&
                (app.localizedName?.isEmpty == false)
            }
            .sorted { lhs, rhs in
                let lhsName = lhs.localizedName ?? ""
                let rhsName = rhs.localizedName ?? ""
                if lhsName.lowercased() != rhsName.lowercased() {
                    return lhsName.lowercased() < rhsName.lowercased()
                }
                if lhsName != rhsName { return lhsName < rhsName }
                return lhs.processIdentifier < rhs.processIdentifier
            }
    }

    static func record(for app: NSRunningApplication) -> AppRecord {
        AppRecord(
            pid: app.processIdentifier,
            name: app.localizedName ?? "Unknown",
            bundleID: app.bundleIdentifier,
            isActive: app.isActive,
            isHidden: app.isHidden,
            isTerminated: app.isTerminated
        )
    }

    static func frontmostApplication() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    static func findRunningApplication(matching query: String) -> NSRunningApplication? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if normalized.contains("."),
           let exactBundle = runningUserApplications().first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(normalized) == .orderedSame }) {
            return exactBundle
        }

        if let exactName = runningUserApplications().first(where: { ($0.localizedName ?? "").caseInsensitiveCompare(normalized) == .orderedSame }) {
            return exactName
        }

        if let exactBundleName = runningUserApplications().first(where: { (appBundleName($0) ?? "").caseInsensitiveCompare(normalized) == .orderedSame }) {
            return exactBundleName
        }

        return runningUserApplications().first(where: {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains(normalized) ||
            (appBundleName($0) ?? "").localizedCaseInsensitiveContains(normalized)
        })
    }

    static func waitForRunningApplication(matching query: String, timeoutMs: Int = launchTimeoutMs) -> NSRunningApplication? {
        let attempts = max(1, timeoutMs / Int(launchPollIntervalMicros / 1_000))
        for _ in 0..<attempts {
            if let app = findRunningApplication(matching: query) {
                return app
            }
            usleep(launchPollIntervalMicros)
        }
        return findRunningApplication(matching: query)
    }

    static func requireRunningApplication(
        matching query: String,
        timeoutMs: Int = launchTimeoutMs,
        action: String
    ) throws -> NSRunningApplication {
        if let app = waitForRunningApplication(matching: query, timeoutMs: timeoutMs) {
            return app
        }
        throw CUAError(message: "timed out after \(timeoutMs / 1000)s waiting to \(action) app: \(query)")
    }

    // The notification observer is installed before the action, and the run loop waits
    // for state changes rather than treating an accepted activation request as success.
    final class ActivationConfirmation: NSObject {
        let verify: () -> Bool
        let runLoop = CFRunLoopGetCurrent()
        private(set) var confirmed = false

        init(verify: @escaping () -> Bool) {
            self.verify = verify
        }

        @objc func notified(_ notification: Notification) {
            check()
        }

        func check() {
            if verify() {
                confirmed = true
                CFRunLoopStop(runLoop)
            }
        }

        func wait(timeout: TimeInterval) -> Bool {
            check()
            let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
            while !confirmed {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { break }
                let result = CFRunLoopRunInMode(.defaultMode, remaining, false)
                if result == .finished || result == .timedOut { break }
            }
            return confirmed && verify()
        }
    }

    static func confirmActivation(
        timeout: TimeInterval = 2,
        subscribe: (ActivationConfirmation) throws -> () -> Void,
        action: () throws -> Void,
        verify: @escaping () -> Bool
    ) rethrows -> Bool {
        let observation = ActivationConfirmation(verify: verify)
        let cleanup = try subscribe(observation)
        defer { cleanup() }
        try action()
        return observation.wait(timeout: timeout)
    }

    static func activateApplication(_ app: NSRunningApplication) -> Bool {
        confirmActivation(subscribe: { observation in
            let center = NSWorkspace.shared.notificationCenter
            center.addObserver(observation, selector: #selector(ActivationConfirmation.notified(_:)),
                               name: NSWorkspace.didActivateApplicationNotification, object: nil)
            return { center.removeObserver(observation) }
        }, action: {
            app.unhide()
            _ = app.activate()
        }, verify: {
            !app.isTerminated && frontmostApplication()?.processIdentifier == app.processIdentifier
        })
    }

    @discardableResult
    static func activate(query: String) throws -> [String: Any] {
        if let app = findRunningApplication(matching: query) {
            guard activateApplication(app) else {
                throw CUAError(message: "failed to confirm activated app: \(query)")
            }
            return [
                "ok": true,
                "launched": false,
                "app": record(for: app).json,
            ]
        }

        try openApplication(query: query, activate: true)
        let app = try requireRunningApplication(matching: query, action: "launch")
        guard activateApplication(app) else {
            throw CUAError(message: "failed to confirm activated app: \(query)")
        }
        return [
            "ok": true,
            "launched": true,
            "app": record(for: app).json,
        ]
    }
}
