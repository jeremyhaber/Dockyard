import AppKit
import ConnectionKit
import DockyardCore
import Foundation

/// Where Keep moves a Scratch file.
enum ScratchKeepDestination: String, CaseIterable, Identifiable {
    case downloads, defaultFolder, ask
    var id: String { rawValue }

    var title: String {
        switch self {
        case .downloads: "Downloads"
        case .defaultFolder: "Default local folder"
        case .ask: "Ask each time"
        }
    }
}

/// Settings for the Scratch folder. Values live in `UserDefaults`.
enum ScratchSettings {
    static let folderKey = "scratchFolder"
    static let hoursKey = "scratchHours"
    static let trashKey = "scratchMovesToTrash"
    static let keepKey = "scratchKeepDestination"

    static let lifetimes = [1, 4, 12, 24, 168]
    static let defaultHours = 12

    static var defaultFolder: String { (NSHomeDirectory() as NSString).appendingPathComponent("Dockyard Scratch") }

    static var folder: String {
        let stored = UserDefaults.standard.string(forKey: folderKey) ?? ""
        return stored.isEmpty ? defaultFolder : stored
    }

    static var hours: Int {
        let stored = UserDefaults.standard.integer(forKey: hoursKey)
        return lifetimes.contains(stored) ? stored : defaultHours
    }

    static var lifetime: TimeInterval { TimeInterval(hours) * 3600 }
    static var lifetimeTitle: String { title(hours: hours) }

    static func title(hours: Int) -> String {
        switch hours {
        case 1: "1 hour"
        case 24: "1 day"
        case 168: "1 week"
        default: "\(hours) hours"
        }
    }

    static var movesToTrash: Bool { UserDefaults.standard.object(forKey: trashKey) as? Bool ?? true }

    static var keepDestination: ScratchKeepDestination {
        UserDefaults.standard.string(forKey: keepKey).flatMap(ScratchKeepDestination.init(rawValue:)) ?? .downloads
    }
}

struct ScratchItem: Identifiable, Equatable {
    var url: URL
    var isDirectory: Bool
    var size: UInt64?
    var expires: Date
    /// "Connection · /folder" for files downloaded through Download to Scratch.
    var origin: String?

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// The Scratch folder: downloads that are removed a set time after they arrive (HANDOFF 7).
///
/// A file's clock starts when it lands in the folder (its date added), or when it was last requested through
/// Download to Scratch if that is later, so downloading a file again restarts it.
@MainActor @Observable
final class ScratchCenter {
    private struct Origin: Codable {
        var source: String
        var requested: Date
    }

    private(set) var items: [ScratchItem] = []
    var selection: Set<URL> = []
    /// Ticks once a minute so the time left stays current.
    private(set) var now = Date()
    private var origins: [String: Origin] = [:]
    private var timer: Task<Void, Never>?
    private var lastCompleted = -1

    var folderURL: URL { URL(fileURLWithPath: ScratchSettings.folder, isDirectory: true) }
    var totalSize: UInt64 { items.compactMap(\.size).reduce(0, +) }
    var selectedItems: [ScratchItem] { items.filter { selection.contains($0.url) } }

    func start() {
        guard timer == nil else { return }
        origins = Self.loadOrigins()
        refresh()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                self?.refresh()
            }
        }
    }

    /// Creates the folder if needed and returns its path.
    func ensureFolder() throws -> String {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL.path
    }

    /// Remembers where files about to be downloaded come from, and restarts their clocks.
    func noteDownload(_ items: [RemoteItem], from connection: String) {
        let requested = Date()
        for item in items {
            origins[item.name] = Origin(source: "\(connection) · \(RemotePath.parent(of: item.path))", requested: requested)
        }
        saveOrigins()
    }

    /// Re-lists the folder when a transfer finishes, so new downloads show up.
    func transfersChanged(_ snapshot: TransferSnapshot) {
        guard snapshot.completedCount != lastCompleted else { return }
        lastCompleted = snapshot.completedCount
        refresh()
    }

    /// Re-lists the folder and removes what has expired.
    func refresh() {
        now = Date()
        let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .creationDateKey, .isDirectoryKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        var listed: [ScratchItem] = []
        var expired: [URL] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: keys)
            var added = values?.addedToDirectoryDate ?? values?.creationDate ?? now
            if let requested = origins[url.lastPathComponent]?.requested, requested > added { added = requested }
            let expires = added.addingTimeInterval(ScratchSettings.lifetime)
            if expires <= now {
                expired.append(url)
                continue
            }
            let isDirectory = values?.isDirectory ?? false
            listed.append(ScratchItem(
                url: url, isDirectory: isDirectory, size: isDirectory ? nil : values?.fileSize.map(UInt64.init),
                expires: expires, origin: origins[url.lastPathComponent]?.source))
        }
        discard(expired)
        listed.sort { $0.expires > $1.expires }
        if listed != items {
            items = listed
            selection.formIntersection(listed.map(\.url))
        }
        // Forget origins whose files are gone, but not ones still downloading.
        let present = Set(listed.map(\.name))
        let before = origins.count
        origins = origins.filter { present.contains($0.key) || $0.value.requested > now.addingTimeInterval(-3600) }
        if origins.count != before { saveOrigins() }
    }

    // MARK: Actions

    func open(_ item: ScratchItem) { NSWorkspace.shared.open(item.url) }

    func reveal(_ items: [ScratchItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.isEmpty ? [folderURL] : items.map(\.url))
    }

    func quickLook(_ items: [ScratchItem]) {
        let files = items.filter { !$0.isDirectory }.map(\.url)
        if !files.isEmpty { QuickLookCenter.shared.show(files) }
    }

    func moveToTrash(_ items: [ScratchItem]) {
        for item in items { try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
        refresh()
    }

    func emptyAll() {
        guard !items.isEmpty, Dialogs.confirm(
            title: "Empty Scratch?",
            message: "\(items.count == 1 ? "1 item" : "\(items.count) items") will be moved to the Trash.",
            confirm: "Empty Scratch") else { return }
        moveToTrash(items)
    }

    /// Moves items out of Scratch so they never expire.
    func keep(_ items: [ScratchItem], app: AppModel) {
        guard !items.isEmpty, let destination = keepDestination() else { return }
        var moved: [URL] = []
        for item in items {
            let target = Self.unusedURL(for: item.name, in: destination)
            do {
                try FileManager.default.moveItem(at: item.url, to: target)
                moved.append(target)
                origins[item.name] = nil
            } catch {
                app.showToast("Could not keep \(item.name): \(error.localizedDescription)", symbol: "exclamationmark.triangle", isError: true)
            }
        }
        saveOrigins()
        refresh()
        guard !moved.isEmpty else { return }
        let what = moved.count == 1 ? moved[0].lastPathComponent : "\(moved.count) items"
        app.showToast("Kept \(what) in \(FileManager.default.displayName(atPath: destination.path))", symbol: "tray.and.arrow.down",
                      action: ToastAction(title: "Show") { NSWorkspace.shared.activateFileViewerSelecting(moved) })
    }

    /// "11h 58m left", "18m left".
    func timeLeft(_ item: ScratchItem) -> String {
        let minutes = max(0, Int(item.expires.timeIntervalSince(now) / 60))
        if minutes < 1 { return "Under a minute left" }
        if minutes < 60 { return "\(minutes)m left" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h \(minutes % 60)m left" }
        return "\(hours / 24)d \(hours % 24)h left"
    }

    /// The share of the lifetime still left, from 1 down to 0.
    func remaining(_ item: ScratchItem) -> Double {
        min(1, max(0, item.expires.timeIntervalSince(now) / ScratchSettings.lifetime))
    }

    // MARK: Private

    private func keepDestination() -> URL? {
        let fm = FileManager.default
        switch ScratchSettings.keepDestination {
        case .downloads:
            return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .defaultFolder:
            return URL(fileURLWithPath: AppSettings.localFolder ?? NSHomeDirectory(), isDirectory: true)
        case .ask:
            let start = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            return Dialogs.chooseFile(directory: start, canChooseDirectories: true)
        }
    }

    private func discard(_ urls: [URL]) {
        let trash = ScratchSettings.movesToTrash
        for url in urls {
            if trash {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func unusedURL(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private static var originsFile: URL {
        AppPaths.supportDirectory.appendingPathComponent("scratch-origins.json")
    }

    private static func loadOrigins() -> [String: Origin] {
        guard let data = try? Data(contentsOf: originsFile) else { return [:] }
        return (try? JSONDecoder().decode([String: Origin].self, from: data)) ?? [:]
    }

    private func saveOrigins() {
        let file = Self.originsFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(origins).write(to: file, options: .atomic)
    }
}
