import DockyardCore
import Foundation

/// What an import of a `.dockyardexport` file changed, in the words the summary sheet shows.
struct ExportImportReport: Equatable {
    var merge: ExportMergeSummary
    var whmTokensRestored = 0
    var settingsApplied: [String] = []
}

struct ExportPreviewCounts: Equatable {
    var connections: Int
    var folders: Int
    var whmSources: Int
}

extension AppModel {
    func exportCounts() async -> ExportPreviewCounts {
        ExportPreviewCounts(
            connections: (try? await connections.fetch(.all).count) ?? allConnections.count,
            folders: (try? await folders.all().count) ?? clientNames.count,
            whmSources: (try? await whmSources.all().count) ?? 0)
    }

    /// Collects everything, seals it with the passphrase (key derivation is slow, so off the main actor) and writes `url`.
    func exportConnections(to url: URL, passphrase: String, includePasswords: Bool) async throws -> ExportPreviewCounts {
        let collector = ExportCollector(connections: connections, folders: folders, whmSources: whmSources, secrets: secrets)
        var contents = try await collector.collect(includeSecrets: includePasswords, settings: SettingsTransfer.collect())
        if includePasswords {
            for source in contents.whmSources {
                if let token = try await secrets.secret(for: source.id, purpose: .cloudToken), !token.isEmpty {
                    contents.whmTokens[source.apiTokenKeychainRef] = token
                }
            }
        }
        let sealed = contents
        let data = try await Task.detached(priority: .userInitiated) { try EncryptedExport.seal(sealed, passphrase: passphrase) }.value
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return ExportPreviewCounts(connections: contents.connections.count, folders: contents.folders.count, whmSources: contents.whmSources.count)
    }

    func openExport(_ data: Data, passphrase: String) async throws -> ExportContents {
        try await Task.detached(priority: .userInitiated) { try EncryptedExport.open(data, passphrase: passphrase) }.value
    }

    /// Merges an opened export. Existing connections win; secrets are only restored for connections this import created.
    func mergeExport(_ contents: ExportContents) async throws -> ExportImportReport {
        let existingSources = Set(try await whmSources.all().map(\.id))
        let merger = ExportMerger(connections: connections, folders: folders, whmSources: whmSources, secrets: secrets)
        var report = ExportImportReport(merge: try await merger.merge(contents))
        let nowSources = Set(try await whmSources.all().map(\.id))
        for source in contents.whmSources where !existingSources.contains(source.id) && nowSources.contains(source.id) {
            guard let token = contents.whmTokens[source.apiTokenKeychainRef] else { continue }
            try await WHMSyncService.storeToken(token, for: source, in: secrets)
            report.whmTokensRestored += 1
        }
        report.settingsApplied = SettingsTransfer.apply(contents.settings)
        applySettings()
        return report
    }
}
