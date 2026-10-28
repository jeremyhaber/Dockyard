import AppKit
import Observation
import Sparkle

/// Sparkle behind "Check for Updates…". The updater only starts when the build carries a real feed URL and
/// public key (`SUFeedURL`, `SUPublicEDKey` in Info.plist); the placeholders shipped in the repository, and demo
/// mode, leave it stopped.
@MainActor @Observable
final class UpdateModel {
    static let shared = UpdateModel()

    private(set) var canCheck = false
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let feed = info["SUFeedURL"] as? String, let url = URL(string: feed), let host = url.host,
              !host.hasSuffix(".invalid"), let key = info["SUPublicEDKey"] as? String, !key.isEmpty,
              !key.hasPrefix("REPLACE") else { return false }
        return true
    }

    private init() {
        guard !DemoMode.isEnabled, Self.isConfigured else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        canCheck = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheck = value }
        }
    }

    var automaticChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        guard let controller else {
            let alert = NSAlert()
            alert.messageText = "Updates are not set up in this build"
            alert.informativeText = DemoMode.isEnabled
                ? "Update checks are turned off in demo mode."
                : "This build has no update feed. Release builds are signed and published with an appcast; see docs/app.md."
            alert.runModal()
            return
        }
        controller.checkForUpdates(nil)
    }
}
