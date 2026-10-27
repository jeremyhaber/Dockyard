import ConnectionKit
import Foundation

/// A stand-in for `op` in demo mode, so the 1Password screens work without the CLI, an account or a network.
enum DemoOnePassword {
    static var cli: OnePasswordCLI {
        OnePasswordCLI(executor: DemoOnePasswordExecutor(), locator: { "/opt/homebrew/bin/op" })
    }

    static let infrastructure = OnePasswordVault(id: "vault-infra", name: "Infrastructure")
    static let clients = OnePasswordVault(id: "vault-clients", name: "Client Sites")

    private static func password(_ item: String, vault: String) -> OnePasswordField {
        OnePasswordField(
            id: "password", type: "CONCEALED", purpose: "PASSWORD", label: "password", value: "demo-secret",
            reference: "op://\(vault)/\(item)/password")
    }

    private static func username(_ name: String) -> OnePasswordField {
        OnePasswordField(id: "username", type: "STRING", purpose: "USERNAME", label: "username", value: name)
    }

    static let items: [OnePasswordItem] = [
        OnePasswordItem(
            id: "demo-harbor", title: "Harbor Books web01", category: .server, vault: infrastructure, tags: ["harbor"],
            fields: [
                OnePasswordField(id: "url", type: "URL", label: "URL", value: "sftp://harborbooks.example"),
                username("harbor"), password("Harbor Books web01", vault: "Infrastructure"),
            ]),
        OnePasswordItem(
            id: "demo-lumen", title: "Lumen Studio assets", category: .server, vault: infrastructure, tags: ["lumen"],
            fields: [
                OnePasswordField(id: "hostname", type: "STRING", label: "hostname", value: "assets.lumenstudio.example"),
                OnePasswordField(id: "port", type: "STRING", label: "port", value: "2222"),
                username("lumen"), password("Lumen Studio assets", vault: "Infrastructure"),
            ]),
        OnePasswordItem(
            id: "demo-key", title: "Deploy key (ed25519)", category: .sshKey, vault: infrastructure,
            fields: [
                OnePasswordField(id: "key_type", type: "STRING", label: "key type", value: "ed25519"),
                OnePasswordField(id: "fingerprint", type: "STRING", label: "fingerprint", value: "SHA256:4f9bQe1xZ0t3mKq7YcVn2hWdRs8LaUjP6oTgXyBzC5E"),
                OnePasswordField(id: "private_key", type: "SSHKEY", label: "private key", value: "-----BEGIN-----"),
            ]),
        OnePasswordItem(
            id: "demo-evergreen", title: "Evergreen staging", category: .sshKey, vault: infrastructure,
            urls: [OnePasswordURL(primary: true, href: "ssh://deploy@staging.evergreenlandscaping.example")],
            fields: [OnePasswordField(id: "private_key", type: "SSHKEY", label: "private key", value: "-----BEGIN-----")]),
        OnePasswordItem(
            id: "demo-juniper", title: "Juniper Cafe hosting", category: .login, vault: clients,
            urls: [OnePasswordURL(primary: true, href: "https://junipercafe.example")],
            fields: [username("juniperc"), password("Juniper Cafe hosting", vault: "Client Sites")]),
        OnePasswordItem(
            id: "demo-granite", title: "Granite Fitness FTP", category: .login, vault: clients, tags: ["fitness"],
            urls: [OnePasswordURL(primary: true, href: "ftps://ftp.granitefitness.example")],
            fields: [username("granite"), password("Granite Fitness FTP", vault: "Client Sites")]),
        OnePasswordItem(
            id: "demo-keystone", title: "Keystone Realty portal", category: .login, vault: clients,
            urls: [OnePasswordURL(primary: true, href: "https://portal.keystonerealty.example")],
            fields: [password("Keystone Realty portal", vault: "Client Sites")]),
        OnePasswordItem(id: "demo-maple", title: "Maple Smiles WP admin", category: .login, vault: clients, fields: []),
    ]

    static func items(inVault vault: String) -> [OnePasswordItem] {
        items.filter { $0.vault.id == vault || $0.vault.name == vault }
    }
}

struct DemoOnePasswordExecutor: CommandExecuting {
    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        let arguments = invocation.arguments
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        let encoder = JSONEncoder()
        switch (arguments.first, arguments.dropFirst().first) {
        case ("account", "list"):
            let account = OnePasswordAccount(url: "dockyard-demo.1password.com", email: "demo@dockyard.example", userUUID: "U1", accountUUID: "A1")
            return CommandResult(exitCode: 0, stdout: try encoder.encode([account]))
        case ("whoami", _):
            return CommandResult(exitCode: 0, stdout: Data("{\"url\":\"dockyard-demo.1password.com\"}".utf8))
        case ("vault", "list"):
            return CommandResult(exitCode: 0, stdout: try encoder.encode([DemoOnePassword.infrastructure, DemoOnePassword.clients]))
        case ("item", "list"):
            var summaries = DemoOnePassword.items(inVault: value(after: "--vault") ?? "")
            for index in summaries.indices { summaries[index].fields = [] }
            return CommandResult(exitCode: 0, stdout: try encoder.encode(summaries))
        case ("item", "get"):
            guard let id = arguments.dropFirst(2).first, let item = DemoOnePassword.items.first(where: { $0.id == id }) else {
                return CommandResult(exitCode: 1, stderr: "[ERROR] 2026/10/25 12:00:00 \"item\" isn't an item")
            }
            return CommandResult(exitCode: 0, stdout: try encoder.encode(item))
        case ("read", _):
            return CommandResult(exitCode: 0, stdout: Data("demo-secret".utf8))
        default:
            return CommandResult(exitCode: 1, stderr: "[ERROR] 2026/10/25 12:00:00 not available in demo mode")
        }
    }
}
