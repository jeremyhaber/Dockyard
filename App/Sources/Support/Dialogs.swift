import AppKit
import UniformTypeIdentifiers

/// Small blocking AppKit dialogs used by context menus.
@MainActor
enum Dialogs {
    static func promptText(title: String, message: String, initial: String = "", confirm: String = "OK") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    static func confirm(title: String, message: String, confirm: String, destructive: Bool = true) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .warning : .informational
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func chooseFile(directory: URL? = nil, canChooseDirectories: Bool = false, showHidden: Bool = true, types: [UTType]? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !canChooseDirectories
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = showHidden
        if let types { panel.allowedContentTypes = types }
        if let directory, FileManager.default.fileExists(atPath: directory.path) { panel.directoryURL = directory }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
