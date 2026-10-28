import AppKit
import DockyardCore
import SwiftUI

/// Website icons, cached on disk without expiry and refreshed in the background when a connection succeeds.
/// Disk reads and network fetches run off the main actor, at most two fetches at a time. Never fetches in demo mode.
@MainActor @Observable
final class FaviconStore {
    static let shared = FaviconStore()

    /// The first icon found for a candidate list, keyed by `key(for:)`.
    private(set) var resolved: [String: NSImage] = [:]
    @ObservationIgnored private var attempted: Set<String> = []
    @ObservationIgnored private var refreshed: Set<String> = []
    private static let limiter = FetchLimiter(slots: 2)

    static func key(for origins: [String]) -> String { origins.joined(separator: " ") }

    func image(for origins: [String]) -> NSImage? { resolved[Self.key(for: origins)] }

    /// Shows the cached icon; fetches only the origins that were never looked up.
    func resolve(_ origins: [String]) async {
        let key = Self.key(for: origins)
        guard !DemoMode.isEnabled, !origins.isEmpty, attempted.insert(key).inserted else { return }
        let cached = await Task.detached(priority: .utility) { Self.readCache(origins) }.value
        show(cached.data, for: key)
        guard cached.missingBeforeHit else { return }
        await fetch(origins, key: key, refetchKnown: false)
    }

    /// Re-fetches a connection's icon after it connects, once per launch. A failed fetch keeps the cached icon.
    func refresh(_ origins: [String]) {
        let key = Self.key(for: origins)
        guard !DemoMode.isEnabled, !origins.isEmpty, refreshed.insert(key).inserted else { return }
        attempted.insert(key)
        Task { await fetch(origins, key: key, refetchKnown: true) }
    }

    private func fetch(_ origins: [String], key: String, refetchKnown: Bool) async {
        let data = await Task.detached(priority: .utility) {
            await Self.fetchAndStore(origins, refetchKnown: refetchKnown)
            return Self.readCache(origins).data
        }.value
        show(data, for: key)
    }

    private func show(_ data: Data?, for key: String) {
        guard let data, let image = NSImage(data: data), image.isValid else { return }
        resolved[key] = image
    }

    // MARK: Disk cache (one file per origin; an empty file records that the site has no icon)

    /// The first cached icon in candidate order, and whether an earlier origin was never looked up.
    private nonisolated static func readCache(_ origins: [String]) -> (data: Data?, missingBeforeHit: Bool) {
        var missing = false
        for origin in origins {
            guard let data = try? Data(contentsOf: cacheFile(for: origin)) else {
                missing = true
                continue
            }
            if !data.isEmpty { return (data, missing) }
        }
        return (nil, missing)
    }

    /// Walks the candidates in order and stops at the first icon. Without `refetchKnown`, origins already in the
    /// cache are not fetched again. A failed fetch never overwrites a cached icon.
    private nonisolated static func fetchAndStore(_ origins: [String], refetchKnown: Bool) async {
        for origin in origins {
            let file = cacheFile(for: origin)
            let cached = try? Data(contentsOf: file)
            if !refetchKnown, let cached {
                if cached.isEmpty { continue } else { return }
            }
            await limiter.acquire()
            let data = await fetch(origin)
            await limiter.release()
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data {
                try? data.write(to: file, options: .atomic)
                return
            }
            if cached?.isEmpty ?? true { try? Data().write(to: file, options: .atomic) }
            if let cached, !cached.isEmpty { return }
        }
    }

    private nonisolated static func cacheFile(for origin: String) -> URL {
        let name = origin.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dockyard/Favicons/\(name)")
    }

    /// Icon links on the home page (largest touch icon first), then `/favicon.ico`.
    private nonisolated static func fetch(_ origin: String) async -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let home = URL(string: origin + "/") else { return nil }
        var candidates: [URL] = []
        if let (data, response) = try? await session.data(from: home), (response as? HTTPURLResponse)?.statusCode == 200 {
            let html = String(decoding: data.prefix(200_000), as: UTF8.self)
            candidates = iconLinks(in: html, base: response.url ?? home)
        }
        candidates.append(home.appendingPathComponent("favicon.ico"))
        for url in candidates {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty, data.count < 1_000_000,
                  NSImage(data: data) != nil else { continue }
            return data
        }
        return nil
    }

    private nonisolated static func iconLinks(in html: String, base: URL) -> [URL] {
        guard let tag = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else { return [] }
        var touch: [URL] = [], icons: [URL] = []
        for match in tag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let element = String(html[range])
            guard let rel = attribute("rel", in: element)?.lowercased(), rel.contains("icon"),
                  let href = attribute("href", in: element), let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  url.pathExtension.lowercased() != "svg" else { continue }
            if rel.contains("apple-touch-icon") { touch.append(url) } else { icons.append(url) }
        }
        return touch + icons
    }

    private nonisolated static func attribute(_ name: String, in element: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: element, range: NSRange(element.startIndex..., in: element)) else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: element) { return String(element[range]) }
        }
        return nil
    }
}

/// Lets at most `slots` icon fetches run at once, so a long sidebar does not flood the network at launch.
actor FetchLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(slots: Int) { available = slots }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

/// A connection's icon: its custom icon, else its website's icon, else its initials on a colour.
struct SiteIcon: View {
    let connection: Connection
    var size: CGFloat = 16

    var body: some View {
        let origins = FaviconCandidates.origins(for: connection)
        content(origins: origins)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            .task(id: FaviconStore.key(for: origins)) {
                if connection.icon == nil { await FaviconStore.shared.resolve(origins) }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(origins: [String]) -> some View {
        switch connection.icon {
        case .symbol(let name, let hex):
            let tint = hex.flatMap(Color.init(hex:)) ?? Color.accentColor
            ZStack {
                tint.opacity(0.16)
                Image(systemName: name)
                    .font(.system(size: size * 0.58, weight: .semibold))
                    .foregroundStyle(tint)
            }
        case .image(let data):
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                monogram
            }
        case nil:
            if let image = FaviconStore.shared.image(for: origins) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                monogram
            }
        }
    }

    private var monogram: some View {
        ZStack {
            Self.monogramColor(connection.name)
            Text(Self.initials(connection.name))
                .font(.system(size: size * (Self.initials(connection.name).count > 1 ? 0.42 : 0.52), weight: .bold))
                .foregroundStyle(.white)
        }
    }

    static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// Stable per name (not `hashValue`, which changes between launches).
    static func monogramColor(_ name: String) -> Color {
        let colors: [Color] = [
            Color(red: 0.04, green: 0.39, blue: 0.81), Color(red: 0.11, green: 0.55, blue: 0.40),
            Color(red: 0.62, green: 0.31, blue: 0.75), Color(red: 0.80, green: 0.40, blue: 0.10),
            Color(red: 0.75, green: 0.20, blue: 0.30), Color(red: 0.20, green: 0.50, blue: 0.62),
            Color(red: 0.42, green: 0.45, blue: 0.50), Color(red: 0.55, green: 0.42, blue: 0.20),
        ]
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return colors[sum % colors.count]
    }
}

extension Color {
    /// `#RRGGBB`.
    init?(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

/// Site editor: pick the sidebar icon.
struct SiteIconSection: View {
    @Binding var draft: SiteDraft
    @State private var error: String?
    /// `draft.faviconSite` once typing pauses, so the preview does not fetch an icon per keystroke.
    @State private var previewSite = ""

    private enum Kind: String, CaseIterable, Identifiable {
        case automatic = "Automatic", symbol = "Symbol", image = "Image"
        var id: String { rawValue }
    }

    private static let symbols = [
        "globe", "server.rack", "cart", "bag", "building.2", "house", "doc.richtext", "photo",
        "envelope", "cloud", "lock.shield", "hammer", "wrench.and.screwdriver", "cube", "leaf", "flame",
        "bolt", "star", "heart", "music.note", "gamecontroller", "graduationcap", "cup.and.saucer", "airplane",
    ]

    var body: some View {
        Section("Icon and colour") {
            HStack(spacing: 12) {
                SiteIcon(connection: previewConnection, size: 32)
                Picker("Icon", selection: kindBinding) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            switch kind {
            case .automatic:
                TextField("Icon from website", text: $draft.faviconSite, prompt: Text("Optional, e.g. example.com"))
                    .task(id: draft.faviconSite) {
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        if !Task.isCancelled { previewSite = draft.faviconSite }
                    }
                if !draft.faviconSite.trimmingCharacters(in: .whitespaces).isEmpty,
                   WebURLResolver.normalizeBase(draft.faviconSite) == nil {
                    Text("Enter a website address, for example example.com.")
                        .font(.caption).foregroundStyle(Palette.statusAmber)
                }
                Text("Uses this website's icon first, then the host's, its parent domain's or a web URL's, or else the site's initials.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            case .symbol:
                symbolGrid
                ColorPicker("Colour", selection: colorBinding, supportsOpacity: false)
            case .image:
                HStack {
                    Button("Choose Image\u{2026}") { chooseImage() }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            ConnectionColorPicker(selection: $draft.color)
            Text("The colour marks this site's tab and panel.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
        }
    }

    private var previewConnection: Connection {
        var c = Connection(id: draft.id, name: draft.name.isEmpty ? (draft.host.isEmpty ? "New" : draft.host) : draft.name, host: draft.host, username: "")
        c.webURLs = draft.webURLs
        c.icon = draft.icon
        let site = previewSite.trimmingCharacters(in: .whitespaces)
        c.faviconSite = site.isEmpty ? nil : site
        return c
    }

    private var kind: Kind {
        switch draft.icon {
        case nil: .automatic
        case .symbol: .symbol
        case .image: .image
        }
    }

    private var kindBinding: Binding<Kind> {
        Binding(get: { kind }, set: { value in
            switch value {
            case .automatic: draft.icon = nil
            case .symbol: if kind != .symbol { draft.icon = .symbol(name: "globe", color: nil) }
            case .image: if kind != .image { chooseImage() }
            }
        })
    }

    private var currentSymbol: (name: String, color: String?)? {
        if case .symbol(let name, let color) = draft.icon { (name, color) } else { nil }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { currentSymbol?.color.flatMap(Color.init(hex:)) ?? .accentColor },
            set: { draft.icon = .symbol(name: currentSymbol?.name ?? "globe", color: $0.hexString) })
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 12), spacing: 6) {
            ForEach(Self.symbols, id: \.self) { name in
                let selected = currentSymbol?.name == name
                Button {
                    draft.icon = .symbol(name: name, color: currentSymbol?.color)
                } label: {
                    Image(systemName: name)
                        .frame(width: 28, height: 28)
                        .background(selected ? Palette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Palette.border))
                }
                .buttonStyle(.plain)
                .help(name)
                .accessibilityLabel(name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func chooseImage() {
        guard let url = Dialogs.chooseFile(types: [.image]) else { return }
        guard let image = NSImage(contentsOf: url), let png = Self.thumbnailPNG(image) else {
            error = "That file is not an image Dockyard can read."
            return
        }
        error = nil
        draft.icon = .image(png)
    }

    /// Scales to fit 64 x 64 and encodes as PNG.
    static func thumbnailPNG(_ image: NSImage) -> Data? {
        let side = 64
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(CGFloat(side) / size.width, CGFloat(side) / size.height)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: (CGFloat(side) - drawn.width) / 2, y: (CGFloat(side) - drawn.height) / 2, width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]), data.count <= ConnectionIcon.maxImageBytes else { return nil }
        return data
    }
}
