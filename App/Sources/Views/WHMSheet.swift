import AppKit
import ConnectionKit
import DockyardCore
import SwiftUI

/// How a WHM server's accounts log in, as the sheet edits it.
enum WHMLoginChoice: String, CaseIterable, Identifiable {
    case throughRoot, password, key, agent
    var id: String { rawValue }

    var title: String {
        switch self {
        case .throughRoot: "Through root"
        case .password: "Password"
        case .key: "SSH key"
        case .agent: "SSH agent"
        }
    }
}

/// Lists the WHM servers and adds or edits one: API access plus how its accounts log in.
struct WHMSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: ConnectionManagerModel
    /// Opens the sheet editing this server.
    var startWith: WHMSource? = nil
    /// The server being edited; nil adds a new one.
    @State private var editing: WHMSource?
    @State private var label = ""
    @State private var host = ""
    @State private var port = "2087"
    @State private var apiUser = "root"
    @State private var token = ""
    @State private var login = WHMLoginChoice.password
    @State private var keyPath = ""
    @State private var passphrase = ""
    @State private var agentChoice = AgentChoice.system
    @State private var agentPath = ""
    /// For "Through root": root logs in with the agent instead of a key file.
    @State private var rootUsesAgent = false
    @State private var busy = false
    @State private var message: String?
    @State private var testing = false
    @State private var testResult: ConnectionTestResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("WHM servers").font(.headline)
            if !model.whmSources.isEmpty { sourceList }
            HStack {
                Text(editing.map { "Edit \($0.label)" } ?? "Add a server").font(.subheadline).foregroundStyle(Palette.textSecondary)
                Spacer()
                if editing != nil { Button("Add a server instead") { startAdding() }.buttonStyle(.link) }
            }
            Form {
                Section {
                    TextField("Label", text: $label, prompt: Text("Optional"))
                    TextField("Host", text: $host, prompt: Text("whm.example.com"))
                    TextField("API port", text: $port)
                    TextField("API user", text: $apiUser)
                    HStack {
                        SecureField("API token", text: $token, prompt: Text(editing == nil ? "" : "Saved; type to replace"))
                        WHMTokenHelp()
                    }
                }
                Section {
                    Picker("Account login", selection: $login) {
                        ForEach(WHMLoginChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: login) { testResult = nil }
                    loginFields
                }
            }
            .formStyle(.columns)
            if let steps = setupSteps {
                SetupStepper(steps: steps).id(login)
            }
            if let message { Text(message).font(.callout).foregroundStyle(Palette.textSecondary) }
            if let testResult {
                Label(testResult.message, systemImage: testResult.success ? "checkmark.circle" : "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(testResult.success ? Palette.statusGreen : Color.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Test Login") { test() }
                    .disabled(!canTest || testing || busy)
                    .help(testHelp)
                if busy || testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add and Sync" : "Save") { editing == nil ? add() : save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || busy)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { if let startWith { startEditing(startWith) } }
    }

    private var sourceList: some View {
        VStack(spacing: 0) {
            ForEach(model.whmSources) { source in
                HStack {
                    VStack(alignment: .leading) {
                        Text(source.label)
                        Text(syncText(source)).font(.caption).foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    Button("Edit") { startEditing(source) }.disabled(editing?.id == source.id)
                    Button("Open WHM") { app.openWHM(source) }
                        .help("Open WHM in your browser, already signed in")
                    Button("Sync now") { sync(source) }.disabled(busy)
                    Button(role: .destructive) {
                        if editing?.id == source.id { startAdding() }
                        Task { try? await app.whmSources.delete(source.id); await model.reload(app: app) }
                    } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Remove \(source.label)")
                }
                .padding(8)
                Divider()
            }
        }
        .background(Palette.chrome, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var loginFields: some View {
        switch login {
        case .throughRoot:
            Picker("Root logs in with", selection: $rootUsesAgent) {
                Text("Key file").tag(false)
                Text("SSH agent").tag(true)
            }
            .pickerStyle(.segmented)
            if rootUsesAgent { agentFields } else { keyFields }
            HStack {
                Spacer()
                Button("Find My Root Key") { findKey() }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || testing || busy)
                    .help("Try the keys in ~/.ssh and your SSH agents against root, and pick the one that works")
            }
            note("Dockyard logs in to the server as root with your root key, then works as each account, so files keep the account's owner. Nothing is set up per account and accounts don't need shell access. Root must be allowed to log in over SSH with a key.")
        case .password:
            note("Dockyard asks for each account's cPanel password the first time you connect to it. WHM does not share account passwords.")
        case .key:
            keyFields
            note("Every account from this server logs in with this key. Its public key must be authorized in each cPanel account.")
        case .agent:
            agentFields
            note("Every account from this server logs in with the keys loaded in the agent.")
        }
        if editing != nil {
            note("Accounts still using this server's previous login switch to this one. Accounts whose login you set yourself keep theirs.")
        }
    }

    @ViewBuilder private var keyFields: some View {
        HStack {
            TextField("Private key", text: $keyPath, prompt: Text("~/.ssh/id_ed25519"))
                .autocorrectionDisabled()
            Button("Choose\u{2026}") { chooseKey() }
        }
        PublicKeyWarning(path: keyPath)
        SecureField("Key passphrase", text: $passphrase, prompt: Text(editing == nil ? "Only if the key is encrypted" : "Saved if set; type to replace"))
    }

    @ViewBuilder private var agentFields: some View {
        Picker("Agent", selection: $agentChoice) {
            ForEach(AgentChoice.allCases) { Text($0.title).tag($0) }
        }
        if agentChoice == .custom {
            TextField("Socket path", text: $agentPath, prompt: Text("~/.ssh/agent.sock")).autocorrectionDisabled()
        }
    }

    /// Setup steps for the chosen login; nil when it needs none.
    private var setupSteps: [String]? {
        let server = host.trimmingCharacters(in: .whitespaces).isEmpty ? "your-server" : host.trimmingCharacters(in: .whitespaces)
        let perAccount = [
            "In WHM, open Manage Shell Access and give each account shell access. Jailed is enough.",
            "For each account, right-click it in Connections and choose Open cPanel. Go to SSH Access \u{2192} Manage SSH Keys \u{2192} Import Key, paste your .pub file, then Manage \u{2192} Authorize.",
        ]
        switch login {
        case .password:
            return nil
        case .throughRoot:
            return [
                "Check that your key logs you in as root: in Terminal, ssh root@\(server) works without a password.",
                "Above, choose that private key (the file without .pub), or SSH agent if the key is in your agent or 1Password.",
                "Click Save. Every account now connects without a password.",
            ]
        case .key:
            return ["Use a key you already have, or create one in Terminal: ssh-keygen -t ed25519"] + perAccount
                + ["Above, choose the private key (the same file without .pub) and click Save."]
        case .agent:
            return ["Load your key into your SSH agent or 1Password."] + perAccount + ["Above, pick that agent and click Save."]
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
    }

    private var canTest: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && accountLogin != nil && login != .password
    }

    private var testHelp: String {
        switch login {
        case .throughRoot: "Log in as root, then open one synced account as that account"
        case .key, .agent: "Open one synced account with this login"
        case .password: "Each account has its own password; test it from the account's site editor"
        }
    }

    private var canSubmit: Bool {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty, editing != nil || !token.isEmpty else { return false }
        return accountLogin != nil
    }

    /// The login the form describes, or nil while a required path is empty.
    private var accountLogin: WHMAccountLogin? {
        switch login {
        case .password:
            return .password
        case .key:
            return keyFile.map { .key(path: $0) }
        case .agent:
            return agentSocket.map { .agent($0) }
        case .throughRoot:
            return rootUsesAgent ? agentSocket.map { .throughRoot(.agent($0)) } : keyFile.map { .throughRoot(.key(path: $0)) }
        }
    }

    private var keyFile: String? {
        let path = keyPath.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    private var agentSocket: AgentSocket? {
        switch agentChoice {
        case .system: return .system
        case .onePassword: return .onePassword
        case .custom:
            let path = agentPath.trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : .custom(path)
        }
    }

    private func syncText(_ s: WHMSource) -> String {
        if let error = s.lastSyncError { return "Last sync failed: \(error)" }
        guard let date = s.lastSyncAt else { return "\(s.host) \u{00B7} never synced" }
        return "\(s.host) \u{00B7} last sync \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func chooseKey() {
        if let path = Dialogs.choosePrivateKey() { keyPath = path }
    }

    private func startEditing(_ source: WHMSource) {
        editing = source
        label = source.label
        host = source.host
        port = String(source.apiPort)
        apiUser = source.apiUser
        token = ""
        passphrase = ""
        keyPath = ""
        agentChoice = .system
        agentPath = ""
        rootUsesAgent = false
        message = nil
        testResult = nil
        switch source.accountLogin {
        case .password:
            login = .password
        case .key(let path):
            login = .key
            keyPath = path
        case .agent(let socket):
            login = .agent
            show(socket)
        case .throughRoot(.key(let path)):
            login = .throughRoot
            keyPath = path
        case .throughRoot(.agent(let socket)):
            login = .throughRoot
            rootUsesAgent = true
            show(socket)
        }
    }

    private func show(_ socket: AgentSocket) {
        switch socket {
        case .system: agentChoice = .system
        case .onePassword: agentChoice = .onePassword
        case .custom(let path):
            agentChoice = .custom
            agentPath = path
        }
    }

    private func startAdding() {
        editing = nil
        label = ""; host = ""; port = "2087"; apiUser = "root"; token = ""
        login = .password; keyPath = ""; passphrase = ""; agentChoice = .system; agentPath = ""; rootUsesAgent = false
        message = nil
        testResult = nil
    }

    private func add() {
        guard let accountLogin else { return }
        busy = true
        let h = host.trimmingCharacters(in: .whitespaces)
        let p = Int(port) ?? 2087
        Task {
            message = await app.addWHMSource(
                label: label, host: h, port: p, apiUser: apiUser, token: token, login: accountLogin, passphrase: passphrase)
            token = ""
            passphrase = ""
            busy = false
            await model.reload(app: app)
        }
    }

    private func save() {
        guard var source = editing, let accountLogin else { return }
        let h = host.trimmingCharacters(in: .whitespaces)
        source.label = label.isEmpty ? h : label
        source.host = h
        source.apiPort = Int(port) ?? 2087
        source.apiUser = apiUser
        source.accountLogin = accountLogin
        busy = true
        Task {
            message = await app.updateWHMSource(source, token: token, passphrase: passphrase)
            token = ""
            passphrase = ""
            editing = source
            busy = false
            await model.reload(app: app)
        }
    }

    private func test() {
        guard let accountLogin else { return }
        testing = true
        testResult = nil
        let h = host.trimmingCharacters(in: .whitespaces)
        Task {
            testResult = await app.testWHMLogin(host: h, login: accountLogin, passphrase: passphrase, source: editing)
            testing = false
        }
    }

    private func findKey() {
        testing = true
        testResult = nil
        let h = host.trimmingCharacters(in: .whitespaces)
        Task {
            let outcome = await app.findRootKey(host: h, passphrase: passphrase, source: editing)
            switch outcome.found {
            case .key(let path):
                rootUsesAgent = false
                keyPath = path
            case .agent(let socket):
                rootUsesAgent = true
                show(socket)
            case nil:
                break
            }
            testResult = ConnectionTestResult(success: outcome.found != nil, message: outcome.message)
            testing = false
        }
    }

    private func sync(_ source: WHMSource) {
        busy = true
        Task {
            message = await app.syncWHM(source)
            busy = false
            await model.reload(app: app)
        }
    }
}

/// One setup step at a time, with Back and Next.
struct SetupStepper: View {
    let steps: [String]
    @State private var index = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Setup \u{00B7} step \(index + 1) of \(steps.count)")
                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                Spacer()
                Link("Full guide", destination: URL(string: "https://github.com/jeremyhaber/Dockyard/blob/main/docs/whm.md")!)
                    .font(.caption)
            }
            Text(steps[index])
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Circle()
                        .fill(i == index ? Color.accentColor : Palette.textSecondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
                Spacer()
                Button { index -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                    .accessibilityLabel("Previous step")
                Button { index += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(index == steps.count - 1)
                    .accessibilityLabel("Next step")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Palette.chrome, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Shown under a key field holding a `.pub` path: SSH logs in with the private half.
struct PublicKeyWarning: View {
    let path: String

    var body: some View {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(".pub") {
            Label("This is the public key. Choose the private key: \(String(trimmed.dropLast(4))).", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Palette.statusAmber)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
