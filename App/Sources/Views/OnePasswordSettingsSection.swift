import ConnectionKit
import SwiftUI

/// Settings, 1Password: whether the CLI is ready and whether 1Password's SSH agent socket exists.
struct OnePasswordSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let center = app.onePassword
        Section("1Password") {
            LabeledContent("Command line tool") {
                HStack(spacing: 6) {
                    if center.checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: center.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(center.isReady ? Palette.statusGreen : Palette.statusAmber)
                            .accessibilityHidden(true)
                    }
                    Text(statusText(center))
                }
            }
            if !center.isReady && !center.checking {
                OnePasswordGuidance(
                    status: center.status, checking: center.checking, failure: center.failure,
                    retry: { Task { await center.refresh() } })
            } else if center.isReady {
                Button("Check Again") { Task { await center.refresh() } }
            }
            LabeledContent("SSH agent") {
                HStack(spacing: 6) {
                    Image(systemName: center.agentSocketFound ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(center.agentSocketFound ? Palette.statusGreen : Palette.textSecondary)
                        .accessibilityHidden(true)
                    Text(center.agentSocketFound ? "Socket found" : "Socket not found")
                }
            }
            Text(center.agentSocketDisplayPath)
                .font(.monoSmall).foregroundStyle(Palette.textSecondary).textSelection(.enabled)
            if !center.agentSocketFound {
                Text("Turn on \u{201C}Use the SSH agent\u{201D} in 1Password, Settings \u{2192} Developer, to use it for SFTP.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
        }
        .task { if center.status == nil { await center.refresh() } }
    }

    private func statusText(_ center: OnePasswordCenter) -> String {
        if center.checking { return "Checking\u{2026}" }
        switch center.status {
        case .ready(let accounts): return accounts.first.map { "Ready, \($0.email.isEmpty ? $0.url : $0.email)" } ?? "Ready"
        case .signedOut: return "1Password is locked"
        case .integrationOff: return "CLI integration is off"
        case .notInstalled: return "Not installed"
        case nil: return center.failure == nil ? "Not checked" : "No answer"
        }
    }
}
