import SwiftUI

/// Asked once at launch when the last session left queued or failed transfers behind.
struct LeftoverSheet: View {
    @Environment(AppModel.self) private var app
    let request: LeftoverRequest
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "tray.full")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(detail).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle("Remember my choice", isOn: $remember)
                .toggleStyle(.checkbox)
                .help("You can change this later in Settings, under Transfers")
            HStack {
                Button("Clear", role: .destructive) { answer(.clear) }
                    .help("Remove the leftover queued and failed transfers")
                Spacer()
                Button("Keep for Later") { answer(.keep) }
                    .help("Leave everything as it is, paused")
                if request.failed > 0 {
                    Button("Retry Failed Too") { answer(.retryFailed) }
                        .help("Continue the queued items and requeue the failed ones")
                }
                Button(request.queued > 0 ? "Resume" : "Retry Failed") { answer(request.queued > 0 ? .resume : .retryFailed) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled()
    }

    private var message: String {
        func count(_ n: Int, _ word: String) -> String { "\(n.formatted()) \(word)" }
        let total = request.queued + request.failed
        let noun = total == 1 ? "transfer" : "transfers"
        switch (request.queued, request.failed) {
        case (let q, 0): return "Your last session left \(count(q, "queued")) \(noun)."
        case (0, let f): return "Your last session left \(count(f, "failed")) \(noun)."
        case (let q, let f): return "Your last session left \(count(q, "queued")) and \(count(f, "failed")) \(noun)."
        }
    }

    private var detail: String {
        if request.queued > 0 {
            return "Queued items are paused until you decide. Resume continues them; failed items stay listed in the Transfers tab."
        }
        return "Failed items stay listed in the Transfers tab until you retry or clear them."
    }

    private func answer(_ choice: LeftoverChoice) {
        app.prompts.resolveLeftovers(request.id, LeftoverAnswer(choice: choice, remember: remember))
    }
}
