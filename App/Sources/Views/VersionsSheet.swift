import ConnectionKit
import DockyardCore
import SwiftUI

/// Old versions and trashed files of one site (`~/.dockyard-trash`): restore, delete now, empty.
struct VersionsSheet: View {
    @Environment(AppModel.self) private var app
    let session: ConnectionSession
    @State private var entries: [TrashEntry] = []
    @State private var selection: Set<TrashEntry.ID> = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var trashRoot = ""
    @State private var conflicts: [PendingRestore] = []
    @State private var confirmDelete = false
    @State private var confirmEmpty = false
    @State private var working = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 760, height: 480)
        .task { await load() }
        .sheet(item: Binding(get: { conflicts.first }, set: { _ in })) { pending in
            RestoreConflictSheet(plan: pending.plan) { choice in resolve(pending.plan, choice) }
        }
        .confirmationDialog("Delete \(selected.count) item\(selected.count == 1 ? "" : "s") from the trash now?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Now", role: .destructive) { deleteSelected() }
        } message: { Text("This frees the space on the server and cannot be undone.") }
        .confirmationDialog("Empty the trash of \(session.connection.name)?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { emptyTrash() }
        } message: { Text("Every kept version and trashed file is deleted from the server for good.") }
    }

    private var selected: [TrashEntry] { entries.filter { selection.contains($0.id) } }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Versions on \(session.connection.name)").font(.headline)
                Text(headerDetail).font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            if loading || working { ProgressView().controlSize(.small) }
        }
        .padding(12)
    }

    private var headerDetail: String {
        let days = AppSettings.trashRetention
        let keeps = [session.connection.keepVersionsOnOverwrite ? "old versions" : nil, session.connection.trashOnDelete ? "deleted files" : nil]
            .compactMap { $0 }
        let policy = keeps.isEmpty ? "This site does not keep copies right now." : "Keeping \(keeps.joined(separator: " and "))."
        return "\(policy) Entries older than \(days) days are purged when you connect. Stored in \(trashRoot.isEmpty ? "~/.dockyard-trash" : trashRoot)."
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            message(icon: "exclamationmark.triangle", text: errorText)
        } else if entries.isEmpty && !loading {
            message(icon: "tray", text: "Nothing is kept for this site.\nTurn on \"Keep old versions when overwriting\" or \"Move deleted files to trash\" in the site settings.")
        } else {
            Table(entries, selection: $selection) {
                TableColumn("Saved") { entry in
                    Text(entry.day).font(.system(size: 12, design: .monospaced))
                }
                .width(90)
                TableColumn("Original path") { entry in
                    HStack(spacing: 6) {
                        Image(systemName: entry.isDirectory ? "folder" : "doc")
                            .foregroundStyle(Palette.textSecondary)
                            .accessibilityHidden(true)
                        Text(entry.originalPath + (entry.version > 1 ? "  (version \(entry.version))" : ""))
                            .font(.system(size: 12))
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                TableColumn("Size") { entry in
                    Text(entry.isDirectory ? "\u{2014}" : FileDisplay.size(entry.size))
                        .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                }
                .width(70)
                TableColumn("Modified") { entry in
                    Text(entry.modified.map { FileDisplay.modifiedCompact($0) } ?? "")
                        .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                }
                .width(110)
            }
            .contextMenu(forSelectionType: TrashEntry.ID.self) { ids in
                Button("Restore") { restore(entries.filter { ids.contains($0.id) }) }
                Button("Delete Now\u{2026}") { selection = ids; confirmDelete = true }
            } primaryAction: { ids in
                restore(entries.filter { ids.contains($0.id) })
            }
            .accessibilityLabel("Kept versions")
        }
    }

    private func message(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(Palette.textSecondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(Palette.textSecondary).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("Restore") { restore(selected) }
                .disabled(selection.isEmpty || working)
            Button("Delete Now\u{2026}") { confirmDelete = true }
                .disabled(selection.isEmpty || working)
            Button("Empty Trash\u{2026}") { confirmEmpty = true }
                .disabled(entries.isEmpty || working)
            Button {
                Task { await load() }
            } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
                .accessibilityLabel("Refresh")
            Spacer()
            Text("\(entries.count) item\(entries.count == 1 ? "" : "s")").font(.caption).foregroundStyle(Palette.textSecondary)
            Button("Done") { app.safety.versionsSessionID = nil }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: Actions

    private var browser: TrashBrowser? {
        guard let fs = session.fs else { return nil }
        let log = session.log
        return TrashBrowser(fs: fs, log: { kind, message in log.append(kind, message) })
    }

    private func load() async {
        guard let browser else {
            errorText = "This connection is not open."
            loading = false
            return
        }
        loading = true
        do {
            trashRoot = try await browser.rootPath()
            entries = try await browser.entries()
            selection = selection.intersection(Set(entries.map(\.id)))
            errorText = nil
        } catch {
            errorText = "Could not read the trash: \(error.userMessage)"
        }
        loading = false
    }

    private func restore(_ list: [TrashEntry]) {
        guard let browser, !list.isEmpty, !working else { return }
        working = true
        Task {
            var restored = 0
            var asking: [PendingRestore] = []
            for entry in list {
                do {
                    let plan = try await browser.restorePlan(for: entry, policy: .ask)
                    if case .needsDecision = plan.action {
                        asking.append(PendingRestore(plan: plan))
                    } else if try await browser.restore(plan).skipped == false {
                        restored += 1
                    }
                } catch {
                    session.log.append(.error, "Restore of \(entry.originalPath) failed: \(error.userMessage)")
                    errorText = "Restore failed: \(error.userMessage)"
                }
            }
            conflicts = asking
            working = false
            finishRestore(count: restored)
            await load()
        }
    }

    private func resolve(_ plan: RestorePlan, _ choice: RestoreConflictPolicy) {
        conflicts.removeAll { $0.id == plan.entry.id }
        guard let browser else { return }
        Task {
            do {
                let result = try await browser.restore(plan.resolving(choice))
                if !result.skipped { finishRestore(count: 1) }
            } catch {
                errorText = "Restore failed: \(error.userMessage)"
            }
            await load()
        }
    }

    private func finishRestore(count: Int) {
        guard count > 0 else { return }
        session.refreshPanes()
        app.showToast("Restored \(count) item\(count == 1 ? "" : "s") on \(session.connection.name)", symbol: "arrow.uturn.backward.circle")
    }

    private func deleteSelected() {
        guard let browser else { return }
        let list = selected
        working = true
        Task {
            for entry in list {
                do { try await browser.deleteNow(entry) } catch { errorText = "Delete failed: \(error.userMessage)" }
            }
            working = false
            await load()
        }
    }

    private func emptyTrash() {
        guard let browser else { return }
        working = true
        Task {
            do { try await browser.empty() } catch { errorText = "Could not empty the trash: \(error.userMessage)" }
            working = false
            await load()
        }
    }
}

private struct PendingRestore: Identifiable {
    let plan: RestorePlan
    var id: String { plan.entry.id }
}

/// What to do when the original path is taken again.
private struct RestoreConflictSheet: View {
    let plan: RestorePlan
    let decide: (RestoreConflictPolicy) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.doc.fill").font(.system(size: 26)).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\"\(plan.entry.name)\" already exists").font(.headline)
                    Text("\(plan.destination) has been replaced or recreated since this copy was kept.")
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Skip") { decide(.skip) }
                Spacer()
                Button("Keep Both") { decide(.rename) }
                    .help("Restore under a new name next to the existing file")
                Button("Replace") { decide(.overwrite) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}
