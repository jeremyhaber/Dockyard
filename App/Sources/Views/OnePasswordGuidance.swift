import ConnectionKit
import SwiftUI

/// What to do when `op` is not ready, as a short checklist with a Retry button.
struct OnePasswordGuidance: View {
    let status: OnePasswordStatus?
    let checking: Bool
    var failure: String?
    let retry: () -> Void

    private static let installCommand = "brew install --cask 1password-cli"

    private var installed: Bool { status != nil && status != .notInstalled }
    private var integrated: Bool {
        switch status {
        case .signedOut, .ready: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(headline).font(.callout.weight(.semibold))
            step(done: installed, number: 1) {
                Text("Install the 1Password command line tool")
                HStack(spacing: 6) {
                    Text(Self.installCommand).font(.monoSmall).textSelection(.enabled)
                    Button {
                        Dialogs.copyToPasteboard(Self.installCommand)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy the command")
                        .accessibilityLabel("Copy install command")
                }
            }
            step(done: integrated, number: 2) {
                Text("In 1Password, open Settings \u{2192} Developer and turn on \u{201C}Integrate with 1Password CLI\u{201D}")
            }
            step(done: status?.isReady == true, number: 3) {
                Text("Unlock 1Password. Dockyard asks it for each secret, and 1Password approves with Touch ID")
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(Palette.statusAmber).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Retry", action: retry).disabled(checking)
                if checking { ProgressView().controlSize(.small) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var headline: String {
        switch status {
        case .notInstalled: "The 1Password CLI is not installed"
        case .integrationOff: "1Password CLI integration is off"
        case .signedOut: "1Password is locked"
        case .ready: "1Password is ready"
        case nil: failure == nil ? "Checking 1Password" : "1Password did not answer"
        }
    }

    private func step<Content: View>(done: Bool, number: Int, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(done ? Palette.statusGreen : Palette.textSecondary)
                .frame(width: 18)
                .accessibilityLabel(done ? "Done" : "Step \(number)")
            VStack(alignment: .leading, spacing: 3) { content() }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
