import AppKit
import ConnectionKit
import DockyardCore
import SwiftUI

struct DrawerView: View {
    @Environment(AppModel.self) private var app
    @State private var errorsOnly = false
    @State private var dragBase = 0.0
    @State private var showSnippets = false

    var body: some View {
        @Bindable var app = app
        let session = app.activeSession
        let hasLines = (session?.logCounts.total ?? 0) > 0
        VStack(spacing: 0) {
            handle
            HStack(spacing: 10) {
                Picker("Drawer", selection: $app.drawerTab) {
                    Text("Log").tag(DrawerTab.log)
                    Text("Terminal").tag(DrawerTab.terminal)
                    Text("Transfers").tag(DrawerTab.transfers)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                switch app.drawerTab {
                case .log:
                    Spacer(minLength: 0)
                    Toggle("Errors only", isOn: $errorsOnly)
                        .toggleStyle(.checkbox)
                    Button("Copy") { copy() }
                        .disabled(!hasLines)
                    Button("Clear") { session?.log.clear() }
                        .disabled(!hasLines)
                case .terminal:
                    if let session, session.status.isConnected, session.shellAvailable {
                        ViewThatFits(in: .horizontal) {
                            terminalControls(session, iconOnly: false)
                            terminalControls(session, iconOnly: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Spacer(minLength: 0)
                    }
                case .transfers:
                    TransfersHeader()
                }
                Button {
                    app.drawerVisible = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close drawer")
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Palette.drawer)
            Group {
                switch app.drawerTab {
                case .log:
                    if let session {
                        LogTableView(session: session, version: session.logVersion, errorsOnly: errorsOnly)
                            .id(session.id)
                    } else {
                        placeholder(icon: "text.alignleft", text: "Open a connection to see its log.")
                    }
                case .terminal:
                    if let session {
                        TerminalPane(session: session)
                    } else {
                        placeholder(icon: "terminal", text: "Open a connection to use its terminal.")
                    }
                case .transfers:
                    TransfersView()
                }
            }
        }
        .frame(height: app.drawerHeight)
        .background(Palette.drawer)
        // The drawer is dark in both appearances, so its controls use the dark control style.
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showSnippets) {
            if let session { SnippetsSheet(session: session) }
        }
    }

    private func terminalControls(_ session: ConnectionSession, iconOnly: Bool) -> some View {
        let controller = session.terminal()
        return HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button {
                if let path = session.server?.currentPath { controller.changeDirectory(to: path) }
            } label: {
                Label("cd to current folder", systemImage: "folder")
            }
            .help("Type cd into the shell for the active server folder")
            Menu {
                ForEach(controller.snippets) { snippet in
                    Button(snippet.name) {
                        controller.type(snippet.command, run: NSEvent.modifierFlags.contains(.option))
                    }
                }
                if !controller.snippets.isEmpty { Divider() }
                Button("Manage Snippets\u{2026}") { showSnippets = true }
            } label: {
                Label("Snippets", systemImage: "text.badge.star")
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Click a snippet to type it, hold Option to run it")
        }
        .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
    }

    private var handle: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(height: 1)
            .overlay {
                Color.clear
                    .frame(height: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if dragBase == 0 { dragBase = app.drawerHeight }
                                app.drawerHeight = min(max(120, dragBase - value.translation.height), 700)
                            }
                            .onEnded { _ in dragBase = 0 }
                    )
            }
            .accessibilityLabel("Resize drawer")
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24))
            Text(text).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copy() {
        guard let session = app.activeSession else { return }
        Dialogs.copyToPasteboard(session.log.copyText(errorsOnly: errorsOnly))
    }
}

/// Title and icon, or just the icon (with its tooltip) when the drawer header is tight.
struct AdaptiveLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
        } else {
            Label(configuration)
        }
    }
}

// MARK: - Log table

struct LogTableView: NSViewRepresentable {
    let session: ConnectionSession
    let version: Int
    let errorsOnly: Bool

    func makeCoordinator() -> LogTableCoordinator { LogTableCoordinator(log: session.log) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        context.coordinator.configure(table)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Palette.ns("DrawerBg")
        scroll.setAccessibilityLabel("Connection log")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(scroll: scroll, version: version, errorsOnly: errorsOnly)
    }
}

@MainActor
final class LogTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let log: LogBuffer
    private weak var table: NSTableView?
    private var lines: [LogLine] = []
    private var lastVersion = -1
    private var lastErrorsOnly = false

    private static let timeID = NSUserInterfaceItemIdentifier("time")
    private static let kindID = NSUserInterfaceItemIdentifier("kind")
    private static let messageID = NSUserInterfaceItemIdentifier("message")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(log: LogBuffer) { self.log = log }

    func configure(_ table: NSTableView) {
        self.table = table
        table.style = .plain
        table.rowHeight = 17
        table.headerView = nil
        table.backgroundColor = Palette.ns("DrawerBg")
        table.intercellSpacing = NSSize(width: 4, height: 0)
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let time = NSTableColumn(identifier: Self.timeID)
        time.width = 66; time.minWidth = 66; time.maxWidth = 66
        let kind = NSTableColumn(identifier: Self.kindID)
        kind.width = 76; kind.minWidth = 76; kind.maxWidth = 76
        let message = NSTableColumn(identifier: Self.messageID)
        message.resizingMask = .autoresizingMask
        message.width = 600
        for c in [time, kind, message] { table.addTableColumn(c) }
        table.dataSource = self
        table.delegate = self
    }

    func update(scroll: NSScrollView, version: Int, errorsOnly: Bool) {
        guard let table, version != lastVersion || errorsOnly != lastErrorsOnly else { return }
        lastVersion = version
        lastErrorsOnly = errorsOnly
        let visible = scroll.contentView.bounds
        let atBottom = lines.isEmpty || visible.maxY >= table.frame.maxY - 24
        lines = log.lines(errorsOnly: errorsOnly)
        table.reloadData()
        if atBottom, !lines.isEmpty { table.scrollRowToVisible(lines.count - 1) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < lines.count else { return nil }
        let line = lines[row]
        let id = column.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? TextCellView) ?? {
            let c = TextCellView()
            c.identifier = id
            c.textField?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            c.textField?.lineBreakMode = .byTruncatingTail
            return c
        }()
        switch id {
        case Self.timeID:
            cell.textField?.stringValue = Self.formatter.string(from: line.time)
            cell.textField?.textColor = NSColor.white.withAlphaComponent(0.55)
        case Self.kindID:
            cell.textField?.stringValue = LogFormat.kindTitle(line.kind)
            cell.textField?.textColor = Palette.logColor(line.kind)
        default:
            cell.textField?.stringValue = line.message
            cell.textField?.textColor = Palette.logColor(line.kind)
        }
        return cell
    }
}
