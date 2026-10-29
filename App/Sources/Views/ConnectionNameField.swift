import AppKit
import DockyardCore
import SwiftUI

/// Where a connection's name is being edited: its tab, or its column header in side by side.
struct RenameTarget: Equatable {
    enum Place { case tab, column }
    let sessionID: UUID
    let place: Place
}

extension AppModel {
    /// Renames the saved connection. WHM sync and imports keep the new name from then on.
    func rename(_ connection: Connection, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != connection.name else { return }
        Task {
            try? await connections.update(connection.id) {
                $0.name = trimmed
                $0.userEditedFields.insert(.name)
            }
        }
    }
}

/// A tab or column header's connection name. Double-click (or the menu's Rename) edits it in place: Return saves,
/// Escape or clicking elsewhere cancels.
struct ConnectionNameField: View {
    @Environment(AppModel.self) private var app
    let session: ConnectionSession
    let place: RenameTarget.Place
    let font: Font
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var target: RenameTarget { RenameTarget(sessionID: session.id, place: place) }

    var body: some View {
        if app.renaming == target {
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .font(font)
                .frame(minWidth: 80)
                .fixedSize()
                .focused($focused)
                .onAppear {
                    draft = session.connection.name
                    focused = true
                }
                .onSubmit {
                    app.rename(session.connection, to: draft)
                    app.renaming = nil
                }
                .onExitCommand { app.renaming = nil }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused, app.renaming == target { app.renaming = nil }
                }
                .accessibilityLabel("Connection name")
        } else {
            Text(session.connection.name)
                .font(font)
                .lineLimit(1)
        }
    }
}
