import SwiftUI

/// Short messages at the bottom right: edit-in-place uploads, moves and renames with their Undo button.
struct ToastStack: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(app.toasts) { toast in
                ToastView(toast: toast)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.toasts)
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var app
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .foregroundStyle(toast.isError ? Color.red : Palette.statusGreen)
                .accessibilityHidden(true)
            Text(toast.text)
                .font(.system(size: 12))
                .lineLimit(2)
                .frame(maxWidth: 380, alignment: .leading)
            if let undo = toast.undo {
                Button("Undo") {
                    app.toasts.removeAll { $0.id == toast.id }
                    app.undo(undo)
                }
                .buttonStyle(.link)
                .font(.system(size: 12, weight: .semibold))
            }
            Button {
                app.toasts.removeAll { $0.id == toast.id }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textSecondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
    }
}
