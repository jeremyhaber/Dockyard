import ConnectionKit
import DockyardCore
import SwiftUI

/// The right-hand panel shown while a WHM server is selected in the Connections sidebar.
struct WHMSourcePanel: View {
    @Environment(AppModel.self) private var app
    let source: WHMSource
    let accountCount: Int
    let edit: () -> Void
    let synced: () async -> Void
    @State private var busy = false
    @State private var syncMessage: String?
    @State private var testResult: ConnectionTestResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.label).font(.headline)
                    Text(source.host).font(.caption).foregroundStyle(Palette.textSecondary).textSelection(.enabled)
                }
                Button { app.openWHM(source) } label: {
                    Label("Open WHM", systemImage: "safari").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .help("Open WHM in your browser, already signed in")

                VStack(alignment: .leading, spacing: 8) {
                    row("Accounts", "\(accountCount)")
                    row("Account login", Self.describe(source.accountLogin))
                    row("Last sync", syncText)
                }

                VStack(spacing: 6) {
                    Button { edit() } label: { Text("Edit Server\u{2026}").frame(maxWidth: .infinity) }
                    Button { sync() } label: { Text("Sync Now").frame(maxWidth: .infinity) }
                    Button { test() } label: { Text("Test Login").frame(maxWidth: .infinity) }
                        .disabled(source.accountLogin == .password)
                        .help(source.accountLogin == .password
                            ? "Each account has its own password; test it from the account's site editor"
                            : "Log in the way this server's accounts do")
                }
                .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                if let syncMessage { Text(syncMessage).font(.caption).foregroundStyle(Palette.textSecondary) }
                if let testResult {
                    Label(testResult.message, systemImage: testResult.success ? "checkmark.circle" : "xmark.octagon")
                        .font(.caption)
                        .foregroundStyle(testResult.success ? Palette.statusGreen : Color.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
        .background(Palette.chromeAlt)
        .onChange(of: source.id) { syncMessage = nil; testResult = nil }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(Palette.textSecondary)
            Text(value).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var syncText: String {
        if let error = source.lastSyncError { return "Failed: \(error)" }
        guard let date = source.lastSyncAt else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func describe(_ login: WHMAccountLogin) -> String {
        switch login {
        case .password: "Each account's password"
        case .key(let path): "Key per account: \(AppModel.describe(.key(path: path)))"
        case .agent(let socket): "Per account with \(AppModel.describe(.agent(socket)))"
        case .throughRoot(let root): "Through root with \(AppModel.describe(root))"
        }
    }

    private func sync() {
        busy = true
        syncMessage = nil
        Task {
            syncMessage = await app.syncWHM(source)
            await synced()
            busy = false
        }
    }

    private func test() {
        busy = true
        testResult = nil
        Task {
            testResult = await app.testWHMLogin(host: source.host, login: source.accountLogin, passphrase: "", source: source)
            busy = false
        }
    }
}

/// The "?" beside the API token: the privileges Dockyard's calls need.
struct WHMTokenHelp: View {
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "questionmark.circle") }
            .buttonStyle(.borderless)
            .accessibilityLabel("API token privileges")
            .popover(isPresented: $shown, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("API token privileges").font(.headline)
                    Text("Create the token in WHM under Development \u{2192} Manage API Tokens. A root token with All Features covers everything. Otherwise tick:")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    privilege("List Accounts", "list-accts", "Required. Syncs the accounts.")
                    privilege("Account Summary", "acct-summary", "Fills in each account's website URLs from its domains and folders.")
                    privilege("Create User Session", "create-user-session", "Open cPanel and Open WHM without a password.")
                    Text("A reseller's token only sees that reseller's accounts.")
                        .font(.caption).foregroundStyle(Palette.textSecondary)
                }
                .padding(14)
                .frame(width: 340)
            }
    }

    private func privilege(_ name: String, _ acl: String, _ why: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(name).font(.callout.weight(.semibold))
                Text(acl).font(.caption.monospaced()).foregroundStyle(Palette.textSecondary)
            }
            Text(why).font(.caption).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
