import ConnectionKit
import DockyardCore
import SwiftUI

struct PromptSheet: View {
    let prompt: ActivePrompt

    var body: some View {
        switch prompt {
        case .conflict(let request): ConflictSheet(request: request)
        case .password(let request): PasswordSheet(request: request)
        case .hostKey(let request): HostKeySheet(request: request)
        }
    }
}

struct ConflictSheet: View {
    @Environment(AppModel.self) private var app
    let request: ConflictRequest
    @State private var applyToAll = false

    var body: some View {
        let info = request.info
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\"\(info.name)\" already exists").font(.headline)
                    Text(info.route).font(.caption).foregroundStyle(Palette.textSecondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Size").foregroundStyle(Palette.textSecondary)
                    Text("Modified").foregroundStyle(Palette.textSecondary)
                }
                GridRow {
                    Text("Incoming")
                    Text(FileDisplay.size(info.sourceSize))
                    Text(FileDisplay.modified(info.sourceModified))
                }
                GridRow {
                    Text("Existing")
                    Text(FileDisplay.size(info.destinationSize))
                    Text(FileDisplay.modified(info.destinationModified))
                }
            }
            .font(.system(size: 12, design: .monospaced))
            Toggle("Apply to all remaining conflicts", isOn: $applyToAll)
            HStack {
                Button("Cancel Transfer") { resolve(.cancel) }
                Spacer()
                Button("Skip") { resolve(.skip) }
                Button("Rename") { resolve(.rename) }
                Button("Overwrite if Newer") { resolve(.overwriteIfNewer) }
                Button("Overwrite") { resolve(.overwrite) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled()
    }

    private func resolve(_ action: ConflictAction) {
        app.prompts.resolveConflict(request.id, ConflictDecision(action, applyToAll: applyToAll))
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
