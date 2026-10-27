import AppKit
import ConnectionKit
import DockyardCore
import SwiftUI

struct TerminalHostView: NSViewRepresentable {
    let controller: TerminalController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let terminal = controller.view
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The Terminal tab: the shell, the amber root bar for PROD sites, or "No shell" for FTP and cloud connections.
struct TerminalPane: View {
    @Environment(AppModel.self) private var app
    let session: ConnectionSession

    var body: some View {
        let connection = session.connection
        VStack(spacing: 0) {
            if session.status.isConnected, session.shellAvailable {
                if connection.isProd, connection.elevation != .none {
                    RootShellBar(session: session)
                }
                shell
            } else if session.status.isConnected {
                NoShellView(connection: connection)
            } else {
                placeholder("terminal", "The terminal opens when the connection is ready.")
            }
        }
        .task(id: session.status) { startIfReady() }
    }

    @ViewBuilder
    private var shell: some View {
        let controller = session.terminal()
        ZStack {
            TerminalHostView(controller: controller)
                .id(session.id)
                .padding(.leading, 6)
            if case .failed(let message) = controller.phase {
                failure(message, controller: controller)
            } else if controller.phase == .ended {
                VStack {
                    Spacer()
                    Button("Start a new shell") { controller.restart() }
                        .controlSize(.small)
                        .padding(.bottom, 12)
                }
            }
        }
        .background(Palette.drawer)
        .onAppear {
            startIfReady()
            controller.focus()
        }
    }

    private func startIfReady() {
        guard session.status.isConnected, session.shellAvailable else { return }
        let controller = session.terminal()
        if controller.phase == .idle { controller.start() }
        Task { await controller.reloadSnippets(from: app.snippets) }
    }

    private func failure(_ message: String, controller: TerminalController) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 22))
            Text("Could not open a shell").font(.headline)
            Text(message).font(.callout).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Try Again") { controller.restart() }
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.drawer)
    }

    private func placeholder(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24))
            Text(text).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoShellView: View {
    let connection: Connection

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 24))
            Text("No shell").font(.headline)
            Text(explanation)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .foregroundStyle(.white.opacity(0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var explanation: String {
        switch connection.protocol {
        case .ftp, .ftps: "FTP servers do not offer a command line. Use an SFTP connection to get a terminal."
        case .rclone: "Cloud storage has no command line. Browse and transfer files in the panes instead."
        case .sftp: "This connection does not allow shell access."
        }
    }
}

/// "Root shell on a PROD site": the shell elevated with su/sudo on a production connection.
struct RootShellBar: View {
    @Environment(AppModel.self) private var app
    let session: ConnectionSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Root shell on a PROD site")
                .font(.system(size: 12, weight: .semibold))
            Text("Commands run as root on \(session.connection.name).")
                .font(.system(size: 12))
                .opacity(0.8)
            Spacer()
            if !session.browsingAsRoot, session.connection.protocol == .sftp {
                Button("Browse files as root") { app.browseAsRoot(session) }
                    .controlSize(.small)
            }
        }
        .foregroundStyle(Color.black.opacity(0.85))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Palette.statusAmber)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Root shell on a PROD site")
    }
}

// MARK: - Snippets

struct SnippetsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let session: ConnectionSession
    @State private var snippets: [Snippet] = []
    @State private var editing: Snippet?
    @State private var name = ""
    @State private var command = ""
    @State private var forThisConnection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snippets").font(.headline)
            Text("Saved commands. Click one in the terminal toolbar to type it; hold Option to run it.")
                .font(.callout).foregroundStyle(Palette.textSecondary)
            if snippets.isEmpty {
                Text("No snippets yet").foregroundStyle(Palette.textSecondary).padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(snippets) { snippet in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(snippet.name).font(.system(size: 13, weight: .medium))
                                Text(snippet.command).font(.monoSmall).foregroundStyle(Palette.textSecondary).lineLimit(1)
                            }
                            Spacer()
                            Text(snippet.connectionId == nil ? "All connections" : "This connection")
                                .font(.caption).foregroundStyle(Palette.textSecondary)
                            Button { begin(snippet) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Edit \(snippet.name)")
                            Button { remove(snippet) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Delete \(snippet.name)")
                        }
                        .padding(8)
                        Divider()
                    }
                }
                .background(Palette.chrome, in: RoundedRectangle(cornerRadius: 6))
            }
            Text(editing == nil ? "New snippet" : "Edit snippet").font(.subheadline).foregroundStyle(Palette.textSecondary)
            TextField("Name", text: $name)
            TextEditor(text: $command)
                .font(.mono)
                .frame(height: 64)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.border))
                .accessibilityLabel("Command")
            Picker("Available on", selection: $forThisConnection) {
                Text("All connections").tag(false)
                Text("This connection only").tag(true)
            }
            .pickerStyle(.segmented)
            HStack {
                if editing != nil { Button("Cancel Edit") { reset() } }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add Snippet" : "Save Snippet") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || command.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
        .task { await reload() }
    }

    private func reload() async {
        snippets = (try? await app.snippets.snippets(for: session.connection.id)) ?? []
        await session.terminal().reloadSnippets(from: app.snippets)
    }

    private func begin(_ snippet: Snippet) {
        editing = snippet
        name = snippet.name
        command = snippet.command
        forThisConnection = snippet.connectionId != nil
    }

    private func reset() {
        editing = nil
        name = ""
        command = ""
        forThisConnection = false
    }

    private func save() {
        let scope = forThisConnection ? session.connection.id : nil
        let order = editing?.sortOrder ?? (snippets.map(\.sortOrder).max() ?? 0) + 1
        let snippet = Snippet(
            id: editing?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces), command: command,
            connectionId: scope, sortOrder: order)
        Task {
            try? await app.snippets.save(snippet)
            reset()
            await reload()
        }
    }

    private func remove(_ snippet: Snippet) {
        Task {
            try? await app.snippets.delete(snippet.id)
            await reload()
        }
    }
}
