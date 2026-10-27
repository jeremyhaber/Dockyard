import ConnectionKit
import DockyardCore
import SwiftUI

struct QuickConnectBar: View {
    @Environment(AppModel.self) private var app
    @State private var choice = QuickProtocol.sftp
    @State private var host = ""
    @State private var user = ""
    @State private var password = ""
    @State private var port = ""
    @FocusState private var hostFocused: Bool

    private var preset: CloudPreset? {
        if case .cloud(let id) = choice { return CloudPreset.preset(id: id) }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Quick Connect")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)

            Menu {
                Button("SFTP") { choice = .sftp }
                Button("FTP") { choice = .ftp }
                Button("FTPS (explicit TLS)") { choice = .ftps }
                Divider()
                Menu("Cloud via rclone") {
                    ForEach(CloudPreset.all) { preset in
                        Button(preset.title) { choice = .cloud(preset.id) }
                    }
                }
            } label: {
                Text(choice.title)
            }
            .menuStyle(.button)
            .fixedSize()
            .accessibilityLabel("Protocol: \(choice.title)")

            if preset == nil || preset?.hostLabel != nil {
                TextField(preset?.hostLabel ?? "Host or sftp://user@host", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, idealWidth: 260)
                    .focused($hostFocused)
                    .onSubmit(connect)
            }
            if preset?.usesOAuth != true {
                TextField(preset?.userLabel ?? "User", text: $user)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onSubmit(connect)
                SecureField(preset?.secretLabel ?? "Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onSubmit(connect)
            }
            if preset == nil {
                TextField("Port", text: $port, prompt: Text(String(choice.connectionProtocol?.defaultPort ?? 22)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .onSubmit(connect)
            }
            Button("Connect", action: connect)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Connect")

            Menu {
                if app.quickHistory.isEmpty {
                    Text("No quick connects yet")
                } else {
                    ForEach(app.quickHistory) { entry in
                        Button(entry.display) { fill(entry) }
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Quick connect history")
            .accessibilityLabel("Quick connect history")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Palette.chromeAlt)
        .onChange(of: app.quickConnectFocusToken) { hostFocused = true }
    }

    private func fill(_ entry: QuickConnectHistoryEntry) {
        switch entry.protocol {
        case .sftp: choice = .sftp
        case .ftp: choice = .ftp
        case .ftps: choice = .ftps
        case .rclone: return
        }
        host = entry.host
        user = entry.username
        port = entry.port == entry.protocol.defaultPort ? "" : String(entry.port)
        password = ""
    }

    private func connect() {
        let snapshot = (choice, host, port, user, password)
        Task {
            await app.quickConnect(choice: snapshot.0, host: snapshot.1, port: snapshot.2, user: snapshot.3, password: snapshot.4)
        }
        password = ""
    }
}
