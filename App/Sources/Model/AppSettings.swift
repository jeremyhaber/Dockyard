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

    static let launchLeftovers = "launchLeftovers"
    static let defaultConflict = "defaultConflict"
    static let globalFilters = "globalTransferFilters"
    static let trashRetentionDays = "trashRetentionDays"

    static let defaultGlobalMaxConnections = 10
    static let globalMaxRange = 1...50
    static let whmHoursRange = 1...48

    static var maxConnections: Int {
        let stored = UserDefaults.standard.integer(forKey: globalMaxConnections)
        return stored == 0 ? defaultGlobalMaxConnections : min(max(stored, globalMaxRange.lowerBound), globalMaxRange.upperBound)
    }

    /// What to do about existing files when nothing more specific applies.
    static var conflictPolicy: ConflictPolicy {
        UserDefaults.standard.string(forKey: defaultConflict).flatMap(ConflictPolicy.init(rawValue:)) ?? .ask
    }

    static var leftoverChoice: LeftoverChoice {
        UserDefaults.standard.string(forKey: launchLeftovers).flatMap(LeftoverChoice.init(rawValue:)) ?? .ask
    }

    /// Skip patterns for folder transfers, compare/sync and watch folders, one per line in Settings.
    static var globalFilterPatterns: [String] {
        guard let text = UserDefaults.standard.string(forKey: globalFilters) else { return TransferFilter.globalDefaults }
        return text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Days a kept version or trashed file stays on the server before it is purged on connect.
    static var trashRetention: Int {
        let stored = UserDefaults.standard.integer(forKey: trashRetentionDays)
        return stored == 0 ? TrashBrowser.defaultRetentionDays : min(max(stored, 1), 365)
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

/// What to do with transfers a previous session left behind.
enum LeftoverChoice: String, CaseIterable, Identifiable {
    case ask, resume, retryFailed, keep, clear
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask"
        case .resume: "Resume"
        case .retryFailed: "Retry failed too"
        case .keep: "Keep for later"
        case .clear: "Clear"
        }
    }
}
