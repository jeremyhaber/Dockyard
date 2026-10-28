import AppKit
import DockyardCore
import Foundation
import QuickLookUI

/// Demo screens for the import, export, jump host and Quick Look features. Demo mode only.
@MainActor
extension AppModel {
    func showImportDemo(_ screen: String) async {
        switch screen {
        case "importPreview":
            presentImportPreview(demoImportPreview()) { _ in }
        case "importUnsupported":
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Servers.exportedServers")
            try? Data([0x00, 0x7B, 0x01, 0xFF, 0x10, 0x42]).write(to: file)
            do { _ = try await prepareImport(.transmit, from: file) } catch let failure as ImportFailure {
                SheetPresenter.present { dismiss in ImportFailureSheet(failure: failure, dismiss: dismiss) }
            } catch {}
        case "export":
            SheetPresenter.present { dismiss in ExportSheet(dismiss: dismiss, prefill: "correct horse battery") }
        case "importExport":
            guard let data = try? demoExportData() else { return }
            let file = URL(fileURLWithPath: "/Users/demo/Documents/Dockyard Connections.dockyardexport")
            SheetPresenter.present { dismiss in ImportExportSheet(file: file, data: data, dismiss: dismiss, prefill: "correct horse battery", autoStart: true) }
        default:
            break
        }
    }

    private func demoImportPreview() -> ImportPreview {
        func bookmark(_ name: String, _ proto: String, _ host: String, user: String, extra: [String: Any] = [:]) -> ImportParseResult {
            var plist: [String: Any] = ["Nickname": name, "Protocol": proto, "Hostname": host, "Username": user]
            plist.merge(extra) { $1 }
            let data = (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
            return CyberduckParser.parseBookmark(data, fileName: "\(name).duckbookmark")
        }
        var parsed = bookmark("Acme production", "ftp", "ftp.acmecorp.example", user: "acme")
        let others = [
            bookmark("Cedar & Pine staging", "sftp", "staging.cedarpine.example", user: "cedar", extra: ["Path": "/var/www/html"]),
            bookmark("Harbor Books", "sftp", "harborbooks.example", user: "harbor", extra: ["Private Key File": "~/.ssh/id_ed25519"]),
            bookmark("Juniper Cafe menu", "ftp-tls", "ftp.junipercafe.example", user: "menu", extra: ["Labels": ["cafe"]]),
            bookmark("Old reseller box", "sftp", "reseller.legacy.example", user: "admin"),
            bookmark("Lumen Studio assets", "sftp", "assets.lumenstudio.example", user: "lumen"),
            bookmark("Offsite archive", "s3", "s3.amazonaws.com", user: "AKIADEMO"),
        ]
        for other in others {
            parsed.sites += other.sites
            parsed.warnings += other.warnings
        }
        return sitePreview(.cyberduck, parsed)
    }

    private func demoExportData() throws -> Data {
        var contents = ExportContents()
        contents.folders = [ClientFolder(name: "Granite Fitness")]
        contents.connections = [
            Connection(name: "Granite Fitness", clientFolderId: contents.folders[0].id, protocol: .sftp, host: "granitefitness.example", username: "granite"),
            Connection(name: "Granite staging", clientFolderId: contents.folders[0].id, protocol: .sftp, host: "staging.granitefitness.example", username: "granite"),
            Connection(name: "Acme Corp", protocol: .ftp, host: "ftp.acmecorp.example", username: "acme"),
        ]
        contents.settings = ["globalMaxConnections": .int(12), "whmSyncHours": .int(4)]
        contents.secrets = [contents.connections[0].id: [.password: "demo"]]
        return try EncryptedExport.seal(contents, passphrase: "correct horse battery", iterations: 1_000)
    }

    /// Shows Quick Look on a sample SVG and points the screenshot script at the panel.
    func showQuickLookDemo() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dockyard-demo-quicklook")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("acme-logo.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="640" height="400" viewBox="0 0 640 400">
          <rect width="640" height="400" fill="#F4F4F6"/>
          <circle cx="320" cy="160" r="86" fill="#0B63CE"/>
          <path d="M270 200 L320 110 L370 200 Z" fill="#FFFFFF"/>
          <text x="320" y="320" font-family="Helvetica" font-size="48" font-weight="bold" text-anchor="middle" fill="#1D1D1F">ACME CORP</text>
        </svg>
        """
        try? svg.write(to: file, atomically: true, encoding: .utf8)
        QuickLookCenter.shared.show([file])
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard let path = DemoMode.windowIDFile, QLPreviewPanel.sharedPreviewPanelExists() else { return }
        try? String(QLPreviewPanel.shared().windowNumber).write(toFile: path, atomically: true, encoding: .utf8)
    }
}
