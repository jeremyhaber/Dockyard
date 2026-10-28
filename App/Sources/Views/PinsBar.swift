import AppKit
import ConnectionKit
import DockyardCore
import SwiftUI

/// A slim row of pinned folders under the server path bar.
struct PinsBar: View {
    @Environment(AppModel.self) private var app
    let pane: PaneModel
    let session: ConnectionSession

    var body: some View {
        let id = session.connection.id
        let pins = app.safety.pins[id] ?? []
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if !pins.isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.leading, 10)
                            .accessibilityHidden(true)
                        ScrollView(.horizontal) {
                            HStack(spacing: 4) {
                                ForEach(pins, id: \.path) { pin in chip(pin) }
                            }
                            .padding(.horizontal, 6)
                        }
                        .scrollIndicators(.hidden)
                    }
                    .frame(height: 24)
                    .background(Palette.chromeAlt)
                    Divider()
                }
            }
        }
        .task(id: id) {
            for await value in app.safety.pinRepository.observe(id) { app.safety.setPins(value, for: id) }
        }
    }

    private func chip(_ pin: PinnedFolder) -> some View {
        let current = pin.path == pane.currentPath
        return Button {
            pane.navigate(to: pin.path)
        } label: {
            Text(pin.title)
                .font(.system(size: 11, weight: current ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(current ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(current ? Color.accentColor.opacity(0.5) : Palette.border))
        }
        .buttonStyle(.plain)
        .help(pin.path)
        .accessibilityLabel("Pinned folder \(pin.title), \(pin.path)")
        .contextMenu {
            Button("Open") { pane.navigate(to: pin.path) }
            Button("Open in New Tab") { pane.openTab(at: pin.path) }
            Divider()
            Button("Unpin") { app.safety.togglePin(pin.path, on: session.connection.id) }
        }
    }
}

/// Pin or unpin the current folder, in the path bar.
struct PinButton: View {
    @Environment(AppModel.self) private var app
    let pane: PaneModel
    let session: ConnectionSession

    var body: some View {
        let pinned = app.safety.isPinned(pane.currentPath, on: session.connection.id)
        Button {
            app.safety.togglePin(pane.currentPath, on: session.connection.id)
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
        }
        .help(pinned ? "Unpin this folder" : "Pin this folder")
        .accessibilityLabel(pinned ? "Unpin this folder" : "Pin this folder")
    }
}

/// Copies the current folder's web address; without a mapping, offers to set one.
struct WebURLButton: View {
    @Environment(AppModel.self) private var app
    let pane: PaneModel
    let session: ConnectionSession

    var body: some View {
        let url = app.webURL(for: pane.currentPath, on: session.connection)
        Menu {
            if let url {
                Button("Copy \(url.absoluteString)") { app.copyWebURLs([pane.currentPath], folder: pane.currentPath, in: session) }
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
                Divider()
                Button("Edit Web URL\u{2026}") { app.editWebURL(at: pane.currentPath, in: session) }
            } else {
                Button("Set Web URL for This Folder\u{2026}") { app.editWebURL(at: pane.currentPath, in: session) }
            }
        } label: {
            Image(systemName: url == nil ? "link.badge.plus" : "link")
        } primaryAction: {
            app.copyWebURLs([pane.currentPath], folder: pane.currentPath, in: session)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(url.map { "Copy \($0.absoluteString)" } ?? "Set a web URL for this folder")
        .accessibilityLabel(url == nil ? "Set web URL" : "Copy web URL")
    }
}

/// Pinned folders at the top of the history popover.
struct PinnedSection: View {
    @Environment(AppModel.self) private var app
    let pane: PaneModel
    let session: ConnectionSession
    let dismiss: () -> Void

    var body: some View {
        let pins = app.safety.pins[session.connection.id] ?? []
        if !pins.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("PINNED")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                ForEach(pins, id: \.path) { pin in
                    Button {
                        if NSEvent.modifierFlags.contains(.command) { pane.openTab(at: pin.path) } else { pane.navigate(to: pin.path) }
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Color.accentColor)
                            Text(pin.title).font(.system(size: 12, weight: .medium))
                            Text(pin.path).font(.monoSmall).foregroundStyle(Palette.textSecondary)
                                .lineLimit(1).truncationMode(.head)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Divider().padding(.top, 4)
            }
        }
    }
}
