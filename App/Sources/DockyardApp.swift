import AppKit
import SwiftUI

@main
struct DockyardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("Dockyard", id: "main") {
            MainWindow()
                .environment(model)
        }
        .defaultSize(width: 1320, height: 820)
        .commands { AppCommands(model: model) }

        Window("Connections", id: "manager") {
            ConnectionManagerView()
                .environment(model)
        }
        .defaultSize(width: 1040, height: 660)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Session state is written before the app exits (the async flush needs a moment, hence `terminateLater`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppModel.shared.prepareForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var pane: PaneModel? {
        guard let session = model.activeSession else { return nil }
        return session.pane(model.focusedSide) ?? session.server
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection\u{2026}") { model.editConnection(nil, origin: .main) }
                .keyboardShortcut("n")
            Button("Quick Connect") { model.requestQuickConnectFocus() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Connections\u{2026}") { openWindow(id: "manager") }
                .keyboardShortcut("o")
            Divider()
            Button("New Folder Tab") { pane?.openTab() }
                .keyboardShortcut("t")
                .disabled(pane == nil)
            Button("Close Folder Tab") { pane?.closeActiveTab() }
                .keyboardShortcut("w")
                .disabled((pane?.state.tabs.count ?? 0) < 2)
            Divider()
            Button("Disconnect") { if let s = model.activeSession { model.disconnect(s) } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!(model.activeSession?.status.isConnected ?? false))
            Button("Close Connection Tab") { if let s = model.activeSession { model.close(s) } }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.activeSession == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .option])
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Jump to Site or Folder\u{2026}") { model.jumpVisible = true }
                .keyboardShortcut("k")
        }

        CommandGroup(after: .toolbar) {
            Button("Refresh") {
                pane?.invalidate()
                pane?.reload()
            }
            .keyboardShortcut("r")
            .disabled(pane == nil)
            Button((pane?.showHidden ?? true) ? "Hide Hidden Files" : "Show Hidden Files") {
                if let pane { pane.setShowHidden(!pane.showHidden) }
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(pane == nil)
            Divider()
            Button(model.drawerVisible ? "Hide Log" : "Show Log") { model.toggleDrawer(tab: .log) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Toggle Terminal") { model.toggleDrawer(tab: .terminal) }
                .keyboardShortcut("`", modifiers: .control)
        }

        CommandMenu("Go") {
            Button("Back") { pane?.goBack() }
                .keyboardShortcut("[")
                .disabled(!(pane?.state.canGoBack ?? false))
            Button("Forward") { pane?.goForward() }
                .keyboardShortcut("]")
                .disabled(!(pane?.state.canGoForward ?? false))
            Button("Up One Folder") { pane?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!(pane?.state.canGoUp ?? false))
            Button("Home Folder") { pane?.goHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(pane == nil)
            Divider()
            Button("Go to Folder\u{2026}") { pane?.requestPathEdit() }
                .keyboardShortcut("g")
                .disabled(pane == nil)
            Button("Edit Path") { pane?.requestPathEdit() }
                .keyboardShortcut("l")
                .disabled(pane == nil)
            Button("Folder History") { model.activeSession?.server?.requestHistory() }
                .keyboardShortcut("y")
                .disabled(model.activeSession?.server == nil)
            Divider()
            Button("Local Pane") { model.focusedSide = .local }
                .keyboardShortcut("1", modifiers: .option)
            Button("Server Pane") { model.focusedSide = .server }
                .keyboardShortcut("2", modifiers: .option)
        }

        CommandGroup(before: .windowList) {
            Button("Dockyard") { openWindow(id: "main") }
            Button("Connections") { openWindow(id: "manager") }
            Divider()
            Button("Next Connection Tab") { cycle(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Connection Tab") { cycle(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
        }
    }

    private func cycle(_ delta: Int) {
        let sessions = model.sessions
        guard sessions.count > 1, let index = sessions.firstIndex(where: { $0.id == model.activeSessionID }) else { return }
        model.activeSessionID = sessions[(index + delta + sessions.count) % sessions.count].id
    }
}
