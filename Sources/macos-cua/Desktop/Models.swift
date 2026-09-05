import Foundation
import CoreGraphics

struct AppRecord {
    let pid: Int32
    let name: String
    let bundleID: String?
    let isActive: Bool
    let isHidden: Bool
    let isTerminated: Bool

    var json: [String: Any] {
        [
            "pid": Int(pid),
            "name": name,
            "bundleId": bundleID as Any,
            "active": isActive,
            "hidden": isHidden,
            "terminated": isTerminated,
        ]
    }

    var line: String {
        var suffix: [String] = []
        if isActive { suffix.append("frontmost") }
        if isHidden { suffix.append("hidden") }
        let flags = suffix.isEmpty ? "" : " [" + suffix.joined(separator: ", ") + "]"
        if let bundleID {
            return "\(name) (pid \(pid), \(bundleID))\(flags)"
        }
        return "\(name) (pid \(pid))\(flags)"
    }
}

struct WindowRecord {
    let id: Int?
    let pid: Int32
    let appName: String
    let title: String
    let bounds: CGRect
    let layer: Int
    let onScreen: Bool
    let isFrontmost: Bool
    // CG-only discovery cannot determine whether an offscreen window is minimized.
    let isMinimized: Bool?

    init(id: Int?, pid: Int32, appName: String, title: String, bounds: CGRect,
         layer: Int, onScreen: Bool, isFrontmost: Bool, isMinimized: Bool? = nil) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.title = title
        self.bounds = bounds
        self.layer = layer
        self.onScreen = onScreen
        self.isFrontmost = isFrontmost
        self.isMinimized = isMinimized
    }

    var json: [String: Any] {
        [
            "id": id.map { $0 as Any } ?? NSNull(),
            "pid": Int(pid),
            "appName": appName,
            "title": title,
            "bounds": CoordinateSupport.rectJSON(bounds),
            "layer": layer,
            "onScreen": onScreen,
            "frontmost": isFrontmost,
            "minimized": isMinimized.map { $0 as Any } ?? NSNull(),
        ]
    }

    var line: String {
        let titleValue = title.isEmpty ? "<untitled>" : title
        let prefix = isFrontmost ? "*" : "-"
        let idValue = id.map(String.init) ?? "n/a"
        return "\(prefix) [\(idValue)] \(appName) | \(titleValue) | \(Int(bounds.origin.x)),\(Int(bounds.origin.y)) \(Int(bounds.size.width))x\(Int(bounds.size.height))"
    }
}
