import ConnectionKit
import DockyardCore
import SwiftUI

/// Folders of one connection, loaded as they are expanded. Used to pick the folder a web address points at.
@MainActor @Observable
final class RemoteFolderPickerModel {
    struct Row: Identifiable {
        let path: String
        let name: String
        let depth: Int
        let expanded: Bool
        let loading: Bool
        var id: String { path }
    }

    private let fs: any RemoteFileSystem
    private var children: [String: [String]] = [:]
    private var expanded: Set<String> = ["/"]
    private var loading: Set<String> = []
    private(set) var error: String?

    init(fs: any RemoteFileSystem) { self.fs = fs }

    var rows: [Row] {
        var out: [Row] = []
        func walk(_ path: String, depth: Int) {
            let open = expanded.contains(path)
            out.append(Row(
                path: path, name: path == "/" ? "/" : RemotePath.lastComponent(of: path), depth: depth,
                expanded: open, loading: loading.contains(path)))
            guard open else { return }
            for child in children[path] ?? [] { walk(child, depth: depth + 1) }
        }
        walk("/", depth: 0)
        return out
    }

    func toggle(_ path: String) {
        if expanded.remove(path) == nil {
            expanded.insert(path)
            Task { await load(path) }
        }
    }

    /// Expands every folder from the root down to `path`.
    func reveal(_ path: String) async {
        var current = "/"
        expanded.insert(current)
        await load(current)
        for part in PathTools.components(of: PathTools.normalize(path)).dropLast() {
            current = RemotePath.join(current, part)
            expanded.insert(current)
            await load(current)
        }
    }

    private func load(_ path: String) async {
        guard children[path] == nil, !loading.contains(path) else { return }
        loading.insert(path)
        defer { loading.remove(path) }
        do {
            let items = try await fs.list(path)
            children[path] = items.filter(\.isDirectory)
                .map(\.path)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            error = nil
        } catch {
            children[path] = []
            self.error = "Could not list \(path): \(error.userMessage)"
        }
    }
}

/// Assigns a web address to a remote folder: the address field, the folder (typed or picked from the tree) and a preview.
struct WebURLSheet: View {
    let connectionName: String
    let fs: (any RemoteFileSystem)?
    /// The connection's other mappings, to warn before one is replaced.
    let existing: [WebURLMapping]
    let originalPath: String?
    let onSave: (WebURLMapping) -> Void
    let onRemove: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var path: String
    @State private var baseURL: String
    @State private var picker: RemoteFolderPickerModel?

    init(
        connectionName: String, fs: (any RemoteFileSystem)?, existing: [WebURLMapping], path: String, baseURL: String,
        originalPath: String?, onSave: @escaping (WebURLMapping) -> Void, onRemove: (() -> Void)?
    ) {
        self.connectionName = connectionName
        self.fs = fs
        self.existing = existing
        self.originalPath = originalPath
        self.onSave = onSave
        self.onRemove = onRemove
        _path = State(initialValue: path)
        _baseURL = State(initialValue: baseURL)
    }

    private var normalizedPath: String { WebURLResolver.normalizePath(path) }
    private var normalizedBase: String? { WebURLResolver.normalizeBase(baseURL) }
    private var replaced: WebURLMapping? {
        existing.first { $0.path == normalizedPath && $0.path != originalPath }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(originalPath == nil ? "Set Web URL" : "Edit Web URL").font(.headline)
            Text("Files in this folder on \(connectionName) are served at this address. \u{201C}Copy Web URL\u{201D} uses the deepest folder that contains a file.")
                .font(.callout)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Base URL") {
                TextField("Base URL", text: $baseURL, prompt: Text("https://example.com"))
                    .labelsHidden()
            }
            LabeledContent("Folder") {
                TextField("Folder", text: $path, prompt: Text("/home/user/public_html"))
                    .labelsHidden()
                    .font(.system(size: 12, design: .monospaced))
            }
            folderTree
            preview
            HStack {
                if let onRemove {
                    Button("Remove", role: .destructive) {
                        onRemove()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let base = normalizedBase else { return }
                    onSave(WebURLMapping(path: normalizedPath, baseURL: base))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(normalizedBase == nil)
            }
        }
        .padding(16)
        .frame(width: 520)
        .task {
            guard let fs, picker == nil else { return }
            let model = RemoteFolderPickerModel(fs: fs)
            picker = model
            await model.reveal(normalizedPath)
        }
    }

    @ViewBuilder
    private var folderTree: some View {
        if let picker {
            ScrollViewReader { proxy in
                List {
                    ForEach(picker.rows) { row in
                        folderRow(row, picker: picker).id(row.path)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(height: 260)
                .onAppear { proxy.scrollTo(normalizedPath, anchor: .center) }
                .onChange(of: picker.rows.count) { proxy.scrollTo(normalizedPath, anchor: .center) }
            }
            if let error = picker.error {
                Text(error).font(.caption).foregroundStyle(Palette.statusAmber)
            }
        } else {
            Text("Connect to this site to pick the folder from its tree.")
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private func folderRow(_ row: RemoteFolderPickerModel.Row, picker: RemoteFolderPickerModel) -> some View {
        let selected = row.path == normalizedPath
        let mapped = existing.first { $0.path == row.path }
        return HStack(spacing: 4) {
            Button { picker.toggle(row.path) } label: {
                Image(systemName: row.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.expanded ? "Collapse \(row.name)" : "Expand \(row.name)")
            Image(systemName: selected ? "folder.fill" : "folder").foregroundStyle(Color.accentColor)
            Text(row.name).lineLimit(1).truncationMode(.middle)
            if row.loading { ProgressView().controlSize(.mini) }
            Spacer(minLength: 4)
            if let mapped {
                Text(mapped.baseURL)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .help("Already served at \(mapped.baseURL)")
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .listRowBackground(selected ? Palette.selection : Color.clear)
        .onTapGesture { path = row.path }
        .onTapGesture(count: 2) { picker.toggle(row.path) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var preview: some View {
        if let base = normalizedBase {
            let sample = WebURLResolver.url(
                for: RemotePath.join(normalizedPath, "index.html"), in: [WebURLMapping(path: normalizedPath, baseURL: base)])
            VStack(alignment: .leading, spacing: 2) {
                Text("\(RemotePath.join(normalizedPath, "index.html")) \u{2192} \(sample?.absoluteString ?? base)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let replaced {
                    Text("Replaces \(replaced.baseURL) for this folder.")
                        .font(.caption).foregroundStyle(Palette.statusAmber)
                }
            }
        } else if !baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Enter an http or https address, for example https://example.com.")
                .font(.caption).foregroundStyle(Palette.statusAmber)
        }
    }
}

/// The main window's sheet for `AppModel.webURLRequest`.
struct WebURLRequestSheet: View {
    @Environment(AppModel.self) private var app
    let request: WebURLRequest

    var body: some View {
        let connection = app.allConnections.first { $0.id == request.connectionId }
        WebURLSheet(
            connectionName: connection?.name ?? "this site",
            fs: app.browsingFileSystem(for: request.connectionId, preferring: request.sessionID),
            existing: connection?.webURLs ?? [],
            path: request.path, baseURL: request.baseURL, originalPath: request.originalPath,
            onSave: { app.saveWebURL($0, replacing: request.originalPath, on: request.connectionId) },
            onRemove: request.originalPath.map { original in { app.removeWebURL(at: original, on: request.connectionId) } })
    }
}

/// Site editor list of folder-to-website mappings.
struct SiteEditorWebURLSection: View {
    @Environment(AppModel.self) private var app
    @Binding var draft: SiteDraft
    @State private var editing: WebURLMapping?
    @State private var adding = false

    var body: some View {
        Section {
            if draft.webURLs.isEmpty {
                Text("No web folders yet. Add one to copy web addresses of files on this site.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            ForEach(draft.webURLs) { mapping in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mapping.baseURL).lineLimit(1)
                        Text(mapping.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Edit\u{2026}") { editing = mapping }
                    Button {
                        draft.webURLs.removeAll { $0.path == mapping.path }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(mapping.baseURL)")
                }
            }
            Button("Add Web URL\u{2026}") { adding = true }
        } header: {
            Text("Web URLs")
        }
        .sheet(item: $editing) { mapping in sheet(path: mapping.path, baseURL: mapping.baseURL, original: mapping.path) }
        .sheet(isPresented: $adding) { sheet(path: suggestedPath, baseURL: "", original: nil) }
    }

    private var suggestedPath: String {
        app.sessions.first { $0.connection.id == draft.id }?.server?.currentPath ?? draft.webURLs.last?.path ?? "/"
    }

    private func sheet(path: String, baseURL: String, original: String?) -> some View {
        WebURLSheet(
            connectionName: draft.name.isEmpty ? draft.host : draft.name,
            fs: app.browsingFileSystem(for: draft.id),
            existing: draft.webURLs, path: path, baseURL: baseURL, originalPath: original,
            onSave: { draft.webURLs = AppModel.applying($0, replacing: original, to: draft.webURLs) },
            onRemove: original.map { original in { draft.webURLs.removeAll { $0.path == original } } })
    }
}
