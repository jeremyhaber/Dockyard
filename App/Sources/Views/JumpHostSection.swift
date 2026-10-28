import ConnectionKit
import DockyardCore
import SwiftUI

/// "Connect through" in the site editor: tunnels this SFTP connection through another saved one.
struct JumpHostSection: View {
    @Environment(AppModel.self) private var app
    @Binding var draft: SiteDraft

    var body: some View {
        let candidates = app.jumpCandidates(for: draft.id)
        Section("Connect through") {
            Picker("Jump host", selection: $draft.jumpHost) {
                Text("Direct connection").tag(UUID?.none)
                ForEach(candidates) { candidate in
                    Text(label(for: candidate)).tag(Optional(candidate.id))
                }
            }
            if let route = route {
                Label {
                    Text(route.joined(separator: "  \u{2192}  "))
                        .font(.monoSmall)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(Palette.textSecondary)
                }
                .accessibilityLabel("Route: \(route.joined(separator: ", then "))")
            }
            Text("Dockyard opens an SSH connection to the jump host, then reaches this server through it. Each host asks to be trusted the first time, and a jump host that needs a password asks for it on connect.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
        }
    }

    private func label(for candidate: Connection) -> String {
        guard let via = candidate.jumpHost, let hop = app.allConnections.first(where: { $0.id == via }) else { return candidate.name }
        return "\(candidate.name) (via \(hop.name))"
    }

    /// Names from the outermost hop to this connection, using the unsaved draft's choice.
    private var route: [String]? {
        guard let hop = draft.jumpHost else { return nil }
        let name = draft.name.isEmpty ? (draft.host.isEmpty ? "This server" : draft.host) : draft.name
        return app.jumpRoute(via: hop, to: name, id: draft.id)
    }
}
