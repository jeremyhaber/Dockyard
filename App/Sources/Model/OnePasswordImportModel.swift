import ConnectionKit
import DockyardCore
import Foundation
import Observation

enum OnePasswordFolderChoice: String, CaseIterable, Identifiable {
    case none, vault, firstTag
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .vault: "Vault name"
        case .firstTag: "First tag of the item"
        }
    }

    var mode: OnePasswordImportOptions.FolderMode {
        switch self {
        case .none: .none
        case .vault: .vault
        case .firstTag: .firstTag
        }
    }
}

enum OnePasswordSecretChoice: String, CaseIterable, Identifiable {
    case reference, copy
    var id: String { rawValue }

    var mode: OnePasswordImportOptions.SecretMode {
        switch self {
        case .reference: .reference
        case .copy: .copyToKeychain
        }
    }
}

/// The result of reading the chosen vaults, ready to show before anything is written.
struct OnePasswordPreview {
    var rows: [ImportRow]
    var warnings: [String]
    var sshKeys: [OnePasswordSSHKey]
    var parsed: ImportParseResult

    var newCount: Int { rows.filter { $0.outcome == .new }.count }
    var updateCount: Int { rows.filter { $0.outcome == .update }.count }
    var duplicateCount: Int { rows.filter { $0.outcome == .duplicate }.count }
    var changeCount: Int { newCount + updateCount }
}

/// The 1Password import dialog: choose vaults, read the items, review, apply.
@MainActor @Observable
final class OnePasswordImportModel {
    enum Phase { case checking, needsSetup, chooseVaults, scanning, preview, applying }

    var phase = Phase.checking
    private(set) var vaults: [OnePasswordVault] = []
    var selectedVaults: Set<String> = []
    var folder = OnePasswordFolderChoice.none
    var secrets = OnePasswordSecretChoice.reference
    var useAgent = false
    private(set) var preview: OnePasswordPreview?
    private(set) var progress = 0
    private(set) var progressTotal = 0
    var error: String?

    @ObservationIgnored private var items: [OnePasswordItem] = []
    @ObservationIgnored private var unreadable: [String] = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private weak var app: AppModel?

    // MARK: Setup

    /// Checks the CLI and lists the vaults.
    func start(app: AppModel) async {
        self.app = app
        phase = .checking
        error = nil
        await app.onePassword.refresh()
        guard app.onePassword.isReady else {
            phase = .needsSetup
            return
        }
        do {
            vaults = try await app.onePassword.cli.vaults()
            if vaults.count == 1 { selectedVaults = Set(vaults.map(\.id)) }
            phase = .chooseVaults
        } catch {
            self.error = error.userMessage
            phase = .needsSetup
        }
    }

    func selectAllVaults() { selectedVaults = Set(vaults.map(\.id)) }

    // MARK: Scan

    func scan() {
        guard let app, !selectedVaults.isEmpty else { return }
        let chosen = vaults.filter { selectedVaults.contains($0.id) }
        phase = .scanning
        error = nil
        progress = 0
        progressTotal = 0
        scanTask = Task { await read(chosen, cli: app.onePassword.cli) }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        phase = .chooseVaults
    }

    private func read(_ chosen: [OnePasswordVault], cli: OnePasswordCLI) async {
        do {
            var summaries: [(id: String, title: String, vault: String)] = []
            for vault in chosen {
                for item in try await cli.items(inVault: vault.id, categories: OnePasswordCLI.defaultCategories) {
                    summaries.append((item.id, item.title, vault.id))
                }
            }
            progressTotal = summaries.count
            let fetched = try await fetch(summaries, cli: cli)
            try Task.checkCancellation()
            items = fetched.items
            unreadable = fetched.warnings
            useAgent = items.contains { $0.category == .sshKey }
            rebuild()
            phase = .preview
        } catch is CancellationError {
            return
        } catch {
            self.error = error.userMessage
            phase = (error as? OnePasswordError)?.needsUserAction == true ? .needsSetup : .chooseVaults
        }
    }

    /// `op item get` is slow, so a few run at once. Unreadable items become warnings; a locked app stops the scan.
    private func fetch(
        _ summaries: [(id: String, title: String, vault: String)], cli: OnePasswordCLI
    ) async throws -> (items: [OnePasswordItem], warnings: [String]) {
        var results = [OnePasswordItem?](repeating: nil, count: summaries.count)
        var warnings: [String] = []
        try await withThrowingTaskGroup(of: (Int, OnePasswordItem?, String?).self) { group in
            var next = 0
            func enqueue() {
                guard next < summaries.count else { return }
                let index = next, summary = summaries[next]
                next += 1
                group.addTask {
                    do {
                        return (index, try await cli.item(id: summary.id, inVault: summary.vault), nil)
                    } catch let failure as OnePasswordError where !failure.needsUserAction {
                        return (index, nil, "Could not read \"\(summary.title)\": \(failure)")
                    }
                }
            }
            for _ in 0..<4 { enqueue() }
            while let (index, item, warning) = try await group.next() {
                results[index] = item
                if let warning { warnings.append(warning) }
                progress += 1
                enqueue()
            }
        }
        return (results.compactMap { $0 }, warnings)
    }

    // MARK: Preview

    /// The options changed: the items are already read, so only the mapping is redone.
    func optionsChanged() {
        if phase == .preview { rebuild() }
    }

    private var options: OnePasswordImportOptions {
        OnePasswordImportOptions(folder: folder.mode, secrets: secrets.mode, useSSHAgent: useAgent)
    }

    private func rebuild() {
        guard let app else { return }
        var scan = OnePasswordImporter.map(items, options: options)
        scan.parsed.warnings = unreadable + scan.parsed.warnings
        let known = Set(app.allConnections.map(\.endpointKey))
        let imported = Dictionary(
            app.allConnections.compactMap { c in c.onePasswordItemId.map { ($0, c) } }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var rows: [ImportRow] = []
        for site in scan.parsed.sites {
            let key = Connection.endpointKey(protocol: site.protocol, host: site.host, port: site.port, username: site.username)
            let outcome: ImportRow.Outcome
            if let id = site.onePasswordItemId, imported[id] != nil {
                outcome = .update
            } else {
                outcome = known.contains(key) || !seen.insert(key).inserted ? .duplicate : .new
            }
            rows.append(ImportRow(
                name: site.name, detail: Self.endpoint(site), folder: site.clientFolderName, outcome: outcome, note: note(for: site)))
        }
        preview = OnePasswordPreview(rows: rows, warnings: scan.parsed.warnings, sshKeys: scan.sshKeys, parsed: scan.parsed)
    }

    private func note(for site: ImportedSite) -> String {
        var parts: [String] = []
        if site.agentSocket == .onePassword { parts.append("1Password SSH agent") }
        if site.secretReferences[.password] != nil {
            parts.append(site.copyReferencesToKeychain ? "Password copied to the Keychain" : "Password stays in 1Password")
        } else if site.authMethods.contains(.password) {
            parts.append("Asks for a password on first connect")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private static func endpoint(_ site: ImportedSite) -> String {
        let account = site.username.isEmpty ? site.host : "\(site.username)@\(site.host)"
        return "\(site.protocol.rawValue)://\(account)" + (site.port == site.protocol.defaultPort ? "" : ":\(site.port)")
    }

    // MARK: Apply

    /// Writes the connections and returns the sentence for the Connections window's banner.
    func apply() async -> String? {
        guard let app, let preview else { return nil }
        phase = .applying
        let importer = SiteImporter(repository: app.connections, folders: app.folders, source: .onePasswordImport, secrets: app.keychainSecrets)
        do {
            let summary = try await importer.apply(preview.parsed, referenceResolver: app.onePassword.cli)
            app.flushSecretCache()
            return Self.sentence(summary)
        } catch {
            self.error = error.userMessage
            phase = .preview
            return nil
        }
    }

    private static func sentence(_ summary: ImportSummary) -> String {
        func plural(_ n: Int) -> String { "\(n) connection\(n == 1 ? "" : "s")" }
        var text = "Imported \(plural(summary.created)) from 1Password"
        if summary.updated > 0 { text += ", updated \(summary.updated)" }
        if summary.skippedDuplicates > 0 { text += ", skipped \(summary.skippedDuplicates) already saved" }
        if summary.referencesStored > 0 { text += ". \(summary.referencesStored) keep their password in 1Password" }
        if summary.passwordsStored > 0 { text += ". \(summary.passwordsStored) password\(summary.passwordsStored == 1 ? "" : "s") copied to the Keychain" }
        if !summary.warnings.isEmpty { text += ".\n" + summary.warnings.prefix(3).joined(separator: "\n") }
        return text
    }
}
