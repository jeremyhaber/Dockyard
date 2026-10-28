import Foundation
import Security

/// Identifiers and locations shared by the app and the Finder extension (docs/app.md, "Finder mount").
enum AppGroup {
    static let identifier = "group.app.dockyard.mac"
    /// The keychain access group without its team prefix; the signed entitlement is `<TEAMID>.app.dockyard.mac.shared`.
    static let keychainGroupSuffix = "app.dockyard.mac.shared"
    static let pollIntervalKey = "finderPollSeconds"

    /// An array entitlement of the running process. Empty in unsigned builds (CI, plain `xcodebuild`).
    static func entitlement(_ key: String) -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else { return [] }
        return value as? [String] ?? []
    }

    /// True when this build carries the App Group entitlement, i.e. the extension can share data with it.
    static var isSigned: Bool { entitlement("com.apple.security.application-groups").contains(identifier) }

    /// Mount controls are hidden unless the Finder extension can load (self-signed and ad-hoc builds cannot).
    static let mountingAvailable = isSigned

    static var containerURL: URL? {
        guard isSigned else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var keychainAccessGroup: String? {
        entitlement("keychain-access-groups").first { $0.hasSuffix(keychainGroupSuffix) }
    }

    /// Defaults the extension can read (polling interval). Plain defaults when the build is unsigned.
    static var sharedDefaults: UserDefaults {
        guard isSigned else { return .standard }
        return UserDefaults(suiteName: identifier) ?? .standard
    }

    static var legacySupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Dockyard", isDirectory: true)
    }

    /// The App Group container when signed, otherwise Application Support.
    static var supportDirectory: URL {
        containerURL?.appendingPathComponent("Dockyard", isDirectory: true) ?? legacySupportDirectory
    }

    static var databaseURL: URL { supportDirectory.appendingPathComponent("dockyard.sqlite") }
}
