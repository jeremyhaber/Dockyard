import DockyardCore
import Foundation

/// Keys and defaults for the Settings window. Values live in `UserDefaults`; the Finder polling interval is
/// also written to the App Group defaults so the extension sees it.
enum AppSettings {
    static let globalMaxConnections = "globalMaxConnections"
    static let writeLogFiles = "writeLogFiles"
    static let defaultLocalFolder = "defaultLocalFolder"
    static let finderPollSeconds = AppGroup.pollIntervalKey
    static let whmSyncHours = "whmSyncHours"

    static let defaultGlobalMaxConnections = 10
    static let globalMaxRange = 1...50
    static let whmHoursRange = 1...48

    static var maxConnections: Int {
        let stored = UserDefaults.standard.integer(forKey: globalMaxConnections)
        return stored == 0 ? defaultGlobalMaxConnections : min(max(stored, globalMaxRange.lowerBound), globalMaxRange.upperBound)
    }

    static var logFilesEnabled: Bool {
        UserDefaults.standard.object(forKey: writeLogFiles) as? Bool ?? true
    }

    /// An existing folder the user chose, or nil.
    static var localFolder: String? {
        guard let path = UserDefaults.standard.string(forKey: defaultLocalFolder), !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    static var whmSyncInterval: TimeInterval {
        let stored = UserDefaults.standard.integer(forKey: whmSyncHours)
        let hours = stored == 0 ? Int(WHMSyncScheduler.defaultInterval / 3600) : min(max(stored, whmHoursRange.lowerBound), whmHoursRange.upperBound)
        return TimeInterval(hours) * 3600
    }
}
