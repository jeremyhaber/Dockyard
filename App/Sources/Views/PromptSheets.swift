import ConnectionKit
import DockyardCore
import SwiftUI

struct PromptSheet: View {
    let prompt: ActivePrompt

    var body: some View {
        switch prompt {
        case .leftovers(let request): LeftoverSheet(request: request)
        case .conflict(let request): ConflictSheet(request: request)
        case .password(let request): PasswordSheet(request: request)
        case .hostKey(let request): HostKeySheet(request: request)
        case .confirm(let request): ConfirmSheet(request: request)
        }
    }
}

struct ConfirmSheet: View {
    @Environment(AppModel.self) private var app
    let request: ConfirmRequest
    @State private var suppress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: request.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(Palette.statusAmber)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.title).font(.headline)
                    Text(request.message).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !request.items.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(request.items, id: \.self) { item in
                        Text(item).font(.monoSmall).lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.chrome, in: RoundedRectangle(cornerRadius: 6))
            }
            if let title = request.suppressTitle {
                Toggle(title, isOn: $suppress).toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button(request.cancelTitle) { app.prompts.resolveConfirm(request.id, confirmed: false) }
                    .keyboardShortcut(.cancelAction)
                Button(request.confirmTitle) { app.prompts.resolveConfirm(request.id, confirmed: true, suppress: suppress) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}

struct PasswordSheet: View {
    @Environment(AppModel.self) private var app
    let request: PasswordRequest
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.headline)
            Text(request.message).foregroundStyle(Palette.textSecondary)
            SecureField(request.fieldLabel, text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { app.prompts.resolvePassword(request.id, nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.isEmpty && !request.allowsEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }

    private func submit() {
        guard !value.isEmpty || request.allowsEmpty else { return }
        app.prompts.resolvePassword(request.id, value)
    }
}

struct HostKeySheet: View {
    @Environment(AppModel.self) private var app
    let request: HostKeyRequest

    private var changed: Bool { request.previousFingerprint != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: changed ? "exclamationmark.shield" : "key")
                    .font(.system(size: 26))
                    .foregroundStyle(changed ? Color.red : Color.accentColor)
                Text(changed ? "The host key for \(request.host) has changed" : "Trust the server \(request.host)?")
                    .font(.headline)
            }
            if changed {
                Text("This could mean the server was reinstalled, or that someone is intercepting the connection. Only continue if you expected this.")
                    .foregroundStyle(Palette.textSecondary)
            } else {
                Text("Dockyard has not connected to this server before. Check the fingerprint with your provider if you can.")
                    .foregroundStyle(Palette.textSecondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(request.algorithm) on port \(request.port)").font(.caption).foregroundStyle(Palette.textSecondary)
                Text(request.fingerprint).font(.monoSmall).textSelection(.enabled)
                if let previous = request.previousFingerprint {
                    Text("Previously trusted").font(.caption).foregroundStyle(Palette.textSecondary).padding(.top, 4)
                    Text(previous).font(.monoSmall).textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.chrome, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Cancel") { app.prompts.resolveHostKey(request.id, trust: false) }
                    .keyboardShortcut(.cancelAction)
                Button(changed ? "Trust New Key" : "Trust and Connect") {
                    app.prompts.resolveHostKey(request.id, trust: true)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }
}
