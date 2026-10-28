import Foundation

/// Launch switches for the screenshot demo: `-DockyardDemo YES` or `DOCKYARD_DEMO=1`.
enum DemoMode {
    static let isEnabled: Bool = {
        UserDefaults.standard.bool(forKey: "DockyardDemo") || ProcessInfo.processInfo.environment["DOCKYARD_DEMO"] == "1"
    }()

    /// `-DockyardDemoScreen main|connectionManager|siteEditor|logDrawer|jump|terminal|sideBySide|compare|editing|settings|transfers|transfersFailed|versions|search|watchFolders|siteEditorSafety|launchPrompt|conflict`
    static let screen: String = UserDefaults.standard.string(forKey: "DockyardDemoScreen") ?? "main"

    /// `-DockyardAppearance dark|light` forces the app's appearance (the system setting is ignored in CI).
    static let appearance: String? = UserDefaults.standard.string(forKey: "DockyardAppearance")

    /// `-DockyardWindowSize 1440x900` sizes the main window regardless of the screen.
    static let windowSize: CGSize? = {
        guard let text = UserDefaults.standard.string(forKey: "DockyardWindowSize") else { return nil }
        let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }()

    /// `-DockyardWindowIDFile <path>`: the app writes the CGWindowID of the window to capture, so the
    /// screenshot script does not have to guess which window is the right one.
    static let windowIDFile: String? = UserDefaults.standard.string(forKey: "DockyardWindowIDFile")

    /// Folder under the temp directory that stands in for ~/Downloads/acme-backups in demo downloads.
    static let downloadsMarker = "dockyard-demo/acme-backups"

    /// Screens that show the Connections window.
    static var opensManager: Bool { ["connectionManager", "healthCheck", "recentlyRemoved"].contains(screen) }

    /// The window the current screen is about.
    static var targetWindow: String {
        switch screen {
        case "connectionManager", "healthCheck", "recentlyRemoved": "manager"
        case "settings": "settings"
        case "watchFolders": "watch"
        case "quickLook": "quickLook"
        default: "main"
        }
    }

    /// All demo timestamps hang off this instant so the data does not drift between runs.
    static let anchor = Date(timeIntervalSince1970: 1_792_929_600)  // 2026-10-25 12:00 UTC
}
