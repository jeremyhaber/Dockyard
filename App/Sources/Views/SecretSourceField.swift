import ConnectionKit
import SwiftUI

/// One secret in the site editor: typed into the Keychain, or read from 1Password through an `op://` reference.
struct SecretSourceField: View {
    @Binding var draft: SiteDraft
    let purpose: SecretPurpose
    let title: String
    let keychainPrompt: String
    @State private var choosing = false

    init(draft: Binding<SiteDraft>, purpose: SecretPurpose, title: String, keychainPrompt: String) {
        _draft = draft
        self.purpose = purpose
        self.title = title
        self.keychainPrompt = keychainPrompt
    }

    private var usesOnePassword: Bool { draft.onePasswordPurposes.contains(purpose) }

    private var reference: Binding<String> {
        Binding(get: { draft.references[purpose] ?? "" }, set: { draft.references[purpose] = $0 })
    }

    private var secret: Binding<String> {
        switch purpose {
        case .keyPassphrase: $draft.keyPassphrase
        case .elevationPassword: $draft.elevationPassword
        default: $draft.password
        }
    }

    var body: some View {
        Picker("\(title) from", selection: Binding(get: { usesOnePassword }, set: setSource)) {
            Text("Keychain").tag(false)
            Text("1Password").tag(true)
        }
        .sheet(isPresented: $choosing) {
            OnePasswordPickerSheet { draft.references[purpose] = $0 }
        }
        if usesOnePassword {
            LabeledContent("Reference") {
                HStack {
                    TextField("Reference", text: reference, prompt: Text("op://Vault/Item/\(fieldHint)"))
                        .labelsHidden()
                        .font(.monoSmall)
                        .autocorrectionDisabled()
                    Button("Choose\u{2026}") { choosing = true }
                }
            }
            validation
        } else {
            SecureField(title, text: secret, prompt: Text(keychainPrompt))
        }
    }

    private var fieldHint: String {
        purpose == .password ? "password" : purpose == .keyPassphrase ? "passphrase" : "field"
    }

    @ViewBuilder
    private var validation: some View {
        let text = (draft.references[purpose] ?? "").trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            note("Paste a secret reference, or pick the field with Choose.", symbol: "info.circle", color: Palette.textSecondary)
        } else if OnePasswordCLI.isValidReference(text) {
            note("Dockyard asks 1Password for it each time it connects. It is not saved in the Keychain.", symbol: "checkmark.circle.fill", color: Palette.statusGreen)
        } else {
            note("Not a valid reference. It looks like op://Vault/Item/field.", symbol: "exclamationmark.triangle.fill", color: Color.red)
        }
    }

    private func note(_ text: String, symbol: String, color: Color) -> some View {
        Label { Text(text).foregroundStyle(Palette.textSecondary) } icon: { Image(systemName: symbol).foregroundStyle(color) }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func setSource(_ onePassword: Bool) {
        if onePassword { draft.onePasswordPurposes.insert(purpose) } else { draft.onePasswordPurposes.remove(purpose) }
    }
}

/// The agent choice under "SSH agent": the system agent, 1Password's, or a socket path.
struct AgentSocketPicker: View {
    @Environment(AppModel.self) private var app
    @Binding var draft: SiteDraft

    var body: some View {
        Picker("Agent", selection: $draft.agentChoice) {
            ForEach(AgentChoice.allCases) { Text($0.title).tag($0) }
        }
        if draft.agentChoice == .custom {
            TextField("Socket path", text: $draft.agentPath, prompt: Text("~/.ssh/agent.sock"))
                .autocorrectionDisabled()
        }
        if draft.agentChoice == .onePassword {
            Label {
                Text(app.onePassword.agentSocketFound
                    ? "Keys stay in 1Password and each use is approved there."
                    : "1Password's agent socket was not found. Turn on \u{201C}Use the SSH agent\u{201D} in 1Password, Settings \u{2192} Developer.")
                    .foregroundStyle(Palette.textSecondary)
            } icon: {
                Image(systemName: app.onePassword.agentSocketFound ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(app.onePassword.agentSocketFound ? Palette.statusGreen : Palette.statusAmber)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .task { if !app.onePassword.agentSocketFound { await app.onePassword.refresh() } }
        }
    }
}

/// Vault, then item, then field: inserts the field's `op://` reference.
struct OnePasswordPickerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let choose: (String) -> Void

    @State private var vaults: [OnePasswordVault] = []
    @State private var items: [OnePasswordItem] = []
    @State private var fields: [OnePasswordField] = []
    @State private var vault: String?
    @State private var item: String?
    @State private var field: String?
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""

    init(choose: @escaping (String) -> Void) { self.choose = choose }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose a 1Password field").font(.headline).padding(16)
            Divider()
            if app.onePassword.isReady {
                columns
            } else {
                OnePasswordGuidance(
                    status: app.onePassword.status, checking: app.onePassword.checking, failure: app.onePassword.failure,
                    retry: { Task { await load() } })
                    .padding(16)
            }
            Divider()
            HStack {
                if loading { ProgressView().controlSize(.small) }
                if let error { Text(error).font(.caption).foregroundStyle(Color.red).lineLimit(2) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Reference") { use() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedReference == nil)
            }
            .padding(12)
        }
        .frame(width: 640)
        .task { await load() }
        .onChange(of: vault) { Task { await loadItems() } }
        .onChange(of: item) { Task { await loadFields() } }
    }

    private var columns: some View {
        HStack(spacing: 0) {
            column("Vault") {
                List(vaults, selection: $vault) { Label($0.name, systemImage: "lock.rectangle.stack") }
            }
            Divider()
            column("Item") {
                VStack(spacing: 0) {
                    TextField("Filter", text: $search).textFieldStyle(.roundedBorder).padding(6)
                    List(filteredItems, selection: $item) { Text($0.title).lineLimit(1) }
                }
            }
            Divider()
            column("Field") {
                List(fields, id: \.id, selection: $field) { field in
                    HStack {
                        Image(systemName: field.isSecret ? "lock.fill" : "text.alignleft")
                            .foregroundStyle(Palette.textSecondary).frame(width: 16).accessibilityHidden(true)
                        Text(field.label.isEmpty ? field.id : field.label).lineLimit(1)
                    }
                }
            }
        }
        .frame(height: 300)
    }

    private func column<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    private var filteredItems: [OnePasswordItem] {
        let text = search.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    /// `op://vault/item/field`, from what `op` reported or built from the ids.
    private var selectedReference: String? {
        guard let vault, let item, let field, let found = fields.first(where: { $0.id == field }) else { return nil }
        return found.reference ?? "op://\(vault)/\(item)/\(found.id)"
    }

    private func use() {
        guard let reference = selectedReference else { return }
        choose(reference)
        dismiss()
    }

    // MARK: Loading

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        await app.onePassword.refresh()
        guard app.onePassword.isReady else { return }
        do { vaults = try await app.onePassword.cli.vaults() } catch { self.error = error.userMessage }
    }

    private func loadItems() async {
        items = []
        fields = []
        item = nil
        field = nil
        guard let vault else { return }
        loading = true
        error = nil
        defer { loading = false }
        do { items = try await app.onePassword.cli.items(inVault: vault, categories: []) } catch { self.error = error.userMessage }
    }

    private func loadFields() async {
        fields = []
        field = nil
        guard let vault, let item else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let full = try await app.onePassword.cli.item(id: item, inVault: vault)
            fields = full.fields.filter { !($0.value ?? "").isEmpty || $0.reference != nil }
        } catch {
            self.error = error.userMessage
        }
    }
}
