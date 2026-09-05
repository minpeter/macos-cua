import AppKit
import Foundation

enum ClipboardSupport {
    static func getText(pasteboard: NSPasteboard = .general) throws -> String {
        pasteboard.string(forType: .string) ?? ""
    }

    static func setText(_ text: String, pasteboard: NSPasteboard = .general) throws {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw CUAError(message: "failed to write clipboard text")
        }
    }

    static func copySelection() throws {
        try InputSupport.keypress("cmd+c")
    }

    static func pasteClipboard() throws {
        try InputSupport.keypress("cmd+v")
    }
}
