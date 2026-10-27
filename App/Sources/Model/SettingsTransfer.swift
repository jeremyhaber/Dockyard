import DockyardCore
import Foundation

/// The Settings values that travel in an encrypted export and the way they are applied on import.
/// Paths and the Touch ID switch are left out: they describe this Mac, not the user's connections.
enum SettingsTransfer {
    private enum Kind { case int(ClosedRange<Int>), double(ClosedRange<Double>), bool }

    private struct Entry {
        var key: String
        var title: String
        var kind: Kind
        var shared = false
    }

    private static let entries: [Entry] = [
        Entry(key: AppSettings.globalMaxConnections, title: "Maximum connections", kind: .int(AppSettings.globalMaxRange)),
        Entry(key: AppSettings.writeLogFiles, title: "Write log files", kind: .bool),
        Entry(key: AppSettings.finderPollSeconds, title: "Finder polling interval", kind: .double(5...3600), shared: true),
        Entry(key: AppSettings.whmSyncHours, title: "WHM sync interval", kind: .int(AppSettings.whmHoursRange)),
    ]

    private static func defaults(_ entry: Entry) -> UserDefaults { entry.shared ? AppGroup.sharedDefaults : .standard }

    /// Values the user has changed from their defaults.
    static func collect() -> [String: SettingValue] {
        var out: [String: SettingValue] = [:]
        for entry in entries {
            guard let object = defaults(entry).object(forKey: entry.key) else { continue }
            switch entry.kind {
            case .int: if let value = object as? Int { out[entry.key] = .int(value) }
            case .double: if let value = object as? Double { out[entry.key] = .double(value) }
            case .bool: if let value = object as? Bool { out[entry.key] = .bool(value) }
            }
        }
        return out
    }

    /// Writes the known keys that are in range and returns a line for each, for the import summary.
    @discardableResult
    static func apply(_ settings: [String: SettingValue]) -> [String] {
        var applied: [String] = []
        for entry in entries {
            guard let value = settings[entry.key] else { continue }
            let store = defaults(entry)
            switch entry.kind {
            case .int(let range):
                guard case .int(let v) = value, range.contains(v) else { continue }
                store.set(v, forKey: entry.key)
                applied.append("\(entry.title): \(v)")
            case .double(let range):
                guard let v = number(value), range.contains(v) else { continue }
                store.set(v, forKey: entry.key)
                applied.append("\(entry.title): \(Int(v))")
            case .bool:
                guard case .bool(let v) = value else { continue }
                store.set(v, forKey: entry.key)
                applied.append("\(entry.title): \(v ? "on" : "off")")
            }
        }
        return applied
    }

    private static func number(_ value: SettingValue) -> Double? {
        switch value {
        case .int(let v): Double(v)
        case .double(let v): v
        default: nil
        }
    }
}
