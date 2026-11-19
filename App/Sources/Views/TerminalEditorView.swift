import AppKit
import DockyardCore
import SwiftUI

/// Hosts the model-owned scroll view, the same way `TerminalHostView` hosts the terminal.
private struct EditorHostView: NSViewRepresentable {
    let model: TerminalEditorModel

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let editor = model.view
        editor.removeFromSuperview()
        editor.frame = container.bounds
        editor.autoresizingMask = [.width, .height]
        container.addSubview(editor)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The editor that replaces the terminal in a shell tab: a control bar, an inline notice row, then the text.
struct TerminalEditorView: View {
    let model: TerminalEditorModel
    @State private var lineText = ""
    @FocusState private var lineFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            bar
            notice
            EditorHostView(model: model)
                .padding(.leading, 2)
            shortcutBar
        }
        .background(Palette.drawer)
        .onChange(of: model.prompt) { _, prompt in
            if prompt == .goToLine { lineText = ""; lineFieldFocused = true }
        }
    }

    // MARK: Control bar

    private var bar: some View {
        HStack(spacing: 8) {
            if model.isModified {
                Circle().fill(.orange).frame(width: 7, height: 7)
                    .help("Unsaved changes").accessibilityLabel("Unsaved changes")
            }
            Text(model.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .help("File being edited").accessibilityLabel("File \(model.name)")
            if model.isNewFile {
                Text("New file").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 5).background(.white.opacity(0.1), in: Capsule())
                    .help("This file does not exist yet; Save creates it on the server")
                    .accessibilityLabel("New file, created on Save")
            }
            Text(model.path).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                .lineLimit(1).truncationMode(.head).layoutPriority(-1)
                .help(model.path).accessibilityLabel("Path \(model.path)")
            Spacer(minLength: 4)
            if model.saving || model.checking {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                    .help(model.checking ? "Checking the file on the server" : "Saving")
            }
            if let note = model.note {
                Text(note).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).layoutPriority(-1).help(note).accessibilityLabel(note)
            }
            Text("Ln \(model.line), Col \(model.column)")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.65)).fixedSize()
                .help("Caret position: line and column").accessibilityLabel("Line \(model.line), column \(model.column)")
            Text(model.format.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).fixedSize()
                .help("File encoding and line endings, kept when you save")
                .accessibilityLabel("Encoding and line endings: \(model.format.label)")
            icon("magnifyingglass", help: "Find and replace (\u{2318}F)") { model.showFind() }
            terminalEditorControl
            overflowMenu
            Button { Task { await model.save() } } label: {
                Text("Save").font(.system(size: 11, weight: .medium))
            }
            .controlSize(.small)
            .disabled(model.saving || (!model.isModified && !model.isNewFile))
            .help("Save to the server (\u{2318}S or \u{2303}O)")
            .accessibilityLabel("Save to the server")
            icon("xmark", help: "Close and return to the shell (Esc, \u{2318}W or \u{2303}X)") { model.requestClose() }
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.white.opacity(0.05))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The less-used actions, so the bar stays readable in a narrow drawer. Save, Find, the terminal editor and Close stay out.
    private var overflowMenu: some View {
        Menu {
            Button("Toggle Comment\u{2003}\u{2318}/") { model.toggleComment(); model.focus() }
                .help("Comment or uncomment the current line or selected lines (\u{2318}/)")
            Button("Check Now\u{2003}\u{2318}\u{21E7}K") { Task { await model.checkNow() } }
                .help("Run the server\u{2019}s syntax checker on the file without saving (\u{2318}\u{21E7}K)")
            Button("Format JSON\u{2003}\u{2325}\u{21E7}F") { model.formatJSON(); model.focus() }
                .disabled(!model.canFormatJSON)
                .help("Format JSON (\u{2325}\u{21E7}F)")
            Divider()
            Toggle("Wrap Long Lines", isOn: Binding(get: { model.wrap }, set: { model.wrap = $0 }))
                .help(model.wrap ? "Wrap long lines (on)" : "Wrap long lines (off)")
            Toggle("Show Shortcut Bar", isOn: Binding(get: { model.showShortcuts }, set: { model.showShortcuts = $0 }))
                .help(model.showShortcuts ? "Hide the shortcut bar" : "Show the shortcut bar")
            Divider()
            Button("Revert to Saved") { model.prompt = nil; Task { await model.revert() } }
                .disabled(!model.isModified || model.saving)
                .help("Revert to the last saved version")
            Button("Open in \(Self.macEditorName)") { model.requestOpenInMacEditor() }
                .help("Open in \(Self.macEditorName) and close this editor")
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 20)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("More: comment (\u{2318}/), check (\u{2318}\u{21E7}K), format JSON (\u{2325}\u{21E7}F), wrap, shortcut bar, revert, open in \(Self.macEditorName)")
        .accessibilityLabel("More editor actions")
    }

    /// Back to the editor the user typed: closes this one so the shell's own `nano`/`vim` runs in place. A file opened
    /// from the file browser has no waiting command, so it offers a choice and types the command into the shell.
    @ViewBuilder
    private var terminalEditorControl: some View {
        if let typed = model.typedEditor {
            Button { model.requestRunInTerminal(typed) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "terminal").font(.system(size: 11, weight: .medium))
                    Text(typed).font(.system(size: 11)).lineLimit(1)
                }
                .padding(.horizontal, 5).frame(height: 20)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close this editor and run \(typed) in the terminal")
            .accessibilityLabel("Open in \(typed): close this editor and run \(typed) in the terminal")
        } else {
            Menu {
                ForEach(["nano", "vim"], id: \.self) { editor in
                    Button(editor) { model.requestRunInTerminal(editor) }
                }
            } label: {
                Image(systemName: "terminal").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 20)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Close this editor and open the file in nano or vim in the terminal")
            .accessibilityLabel("Open in a terminal editor: nano or vim")
        }
    }

    private func icon(
        _ symbol: String, help: String, on: Bool = false, disabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .background(on ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Shortcut bar

    private struct Shortcut: Identifiable {
        let keys: String, label: String, help: String
        let run: (EditorTextView) -> Void
        var id: String { keys }
    }

    private var shortcuts: [Shortcut] {
        [
            Shortcut(keys: "^O", label: "Save", help: "Write out: save to the server (^O)") { _ in Task { await model.save() } },
            Shortcut(keys: "^X", label: "Close", help: "Close the editor and return to the shell (^X)") { _ in model.requestClose() },
            Shortcut(keys: "^W", label: "Where Is", help: "Find (^W)") { _ in model.showFind() },
            Shortcut(keys: "^\\", label: "Replace", help: "Find and replace (^\\)") { $0.showFind(replace: true) },
            Shortcut(keys: "^K", label: "Cut", help: "Cut the current line, or the marked region (^K). Repeated cuts add up") { $0.cutForNano() },
            Shortcut(keys: "^U", label: "Paste", help: "Paste the last cut text (^U)") { $0.pasteForNano() },
            Shortcut(keys: "^_", label: "Go To Line", help: "Go to a line number (^_)") { _ in model.prompt = .goToLine },
            Shortcut(keys: "M-U", label: "Undo", help: "Undo (Option-U); Option-E redoes") { $0.undoForNano() },
            Shortcut(keys: "\u{2318}/", label: "Comment", help: "Comment or uncomment the current line or selection (\u{2318}/)") { _ in model.toggleComment() },
        ]
    }

    private func shortcutRow(_ count: Int) -> some View {
        HStack(spacing: 10) {
            ForEach(shortcuts.prefix(count)) { item in
                Button {
                    item.run(model.view.textView)
                    model.focus()
                } label: {
                    HStack(spacing: 3) {
                        Text(item.keys).font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 3).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 2))
                            .foregroundStyle(.black)
                        Text(item.label).font(.system(size: 10)).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.help)
                .accessibilityLabel(item.help)
            }
            Spacer(minLength: 0)
        }
    }

    /// One row; shows as many keys as fit.
    @ViewBuilder
    private var shortcutBar: some View {
        if model.showShortcuts {
            ViewThatFits(in: .horizontal) {
                ForEach([9, 8, 6, 4, 2], id: \.self) { count in shortcutRow(count) }
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Color.white.opacity(0.05))
            .overlay(alignment: .top) { Divider() }
        }
    }

    static var macEditorName: String {
        AppSettings.editorURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? "the default app"
    }

    // MARK: Notices

    @ViewBuilder
    private var notice: some View {
        if let message = model.error {
            row {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 4)
                Button("Dismiss") { model.error = nil }
            }
        } else if let prompt = model.prompt {
            switch prompt {
            case .unsaved(let then):
                row {
                    Text("Save changes to \(model.name)?").lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Save") { model.saveAndProceed(then) }
                    Button("Discard") { model.discardAndProceed(then) }
                    Button("Cancel") { model.dismissPrompt() }
                }
            case .conflict(let then):
                row {
                    Text("\(model.name) changed on the server since you opened it.").lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Overwrite") { Task { await model.save(overwrite: true, then: then) } }
                    Button("Reload") { Task { await model.revert() } }
                    Button("Cancel") { model.dismissPrompt() }
                }
            case .problems(let then):
                row(tint: .red) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(model.problemSummary).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("Go to") { model.goToFirstProblem() }
                    Button("Save anyway") { model.saveAnyway(then: then) }
                    Button("Cancel") { model.dismissPrompt() }
                }
            case .checkResult:
                row(tint: .red) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(model.problemSummary).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("Go to") { model.goToFirstProblem() }
                    Button("Dismiss") { model.dismissPrompt() }
                }
            case .configFailed:
                if let failure = model.configFailure {
                    row(tint: .red) {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(failure.test.label) failed. Saved, but the server may not accept it:").lineLimit(1)
                            ForEach(Array(failure.lines.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                                    .truncationMode(.middle).help(line)
                            }
                        }
                        .textSelection(.enabled)
                        Spacer(minLength: 4)
                        if failure.previous != nil {
                            Button("Restore previous version") { Task { await model.restorePreviousVersion() } }
                        }
                        Button("Keep") { model.keepAfterConfigFailure() }
                    }
                }
            case .goToLine:
                row {
                    Text("Go to line")
                    TextField("", text: $lineText)
                        .textFieldStyle(.roundedBorder).frame(width: 70).focused($lineFieldFocused)
                        .onSubmit {
                            if let number = Int(lineText.trimmingCharacters(in: .whitespaces)) { model.goToLine(number) }
                            model.dismissPrompt()
                        }
                    Spacer(minLength: 4)
                    Button("Cancel") { model.dismissPrompt() }
                }
            }
        }
    }

    private func row<Content: View>(tint: Color = .orange, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .font(.system(size: 11))
            .controlSize(.small)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(tint.opacity(0.14))
            .overlay(alignment: .bottom) { Divider() }
    }
}
