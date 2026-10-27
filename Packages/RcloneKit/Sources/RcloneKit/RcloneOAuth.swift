import ConnectionKit
import Foundation

/// Runs rclone's own OAuth flow (local redirect server plus browser) and returns the token JSON.
///
/// The app stores the result as the connection's `.cloudToken` secret. rclone writes the token into a
/// throwaway config file inside a private temp directory, which is removed before this returns.
public struct RcloneOAuth: Sendable {
    public let client: RcloneClient

    public init(client: RcloneClient) {
        self.client = client
    }

    private struct Step: Decodable {
        struct Option: Decodable { var Name: String; var Default: JSONValue? }
        var State: String?
        var Option: Option?
        var Error: String?
    }

    public func authorize(
        backend: RcloneBackend,
        options: [String: String] = [:]
    ) async throws -> String {
        guard backend.usesOAuth else {
            throw RemoteError.invalidConfiguration("\(backend.rawValue) does not use OAuth")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dockyard-oauth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let name = "dockyard-oauth"
        try await client.call("config/setpath", ["path": .string(directory.appendingPathComponent("rclone.conf").path)])
        var parameters = JSONValue.object(options.mapValues { .string($0) })
        if case .object(var dict) = parameters {
            dict["config_is_local"] = "true"
            parameters = .object(dict)
        }

        var opt: [String: JSONValue] = ["nonInteractive": true]
        for _ in 0..<20 {
            let data = try await client.call("config/create", [
                "name": .string(name), "type": .string(backend.rawValue), "parameters": parameters, "opt": .object(opt),
            ])
            let step = try JSONDecoder().decode(Step.self, from: data)
            if let error = step.Error, !error.isEmpty { throw RemoteError.authenticationFailed(error) }
            guard let state = step.State, !state.isEmpty else { break }
            let answer: String
            switch step.Option?.Name {
            case "config_is_local": answer = "true"
            default:
                if case .string(let value)? = step.Option?.Default { answer = value } else { answer = "" }
            }
            opt = ["nonInteractive": true, "continue": true, "state": .string(state), "result": .string(answer)]
        }

        defer { Task { _ = try? await client.call("config/delete", ["name": .string(name)], quiet: true) } }
        let values = try await client.call("config/get", ["name": .string(name)], as: [String: JSONValue].self, quiet: true)
        guard case .string(let token)? = values["token"], !token.isEmpty else {
            throw RemoteError.authenticationFailed("Authorisation did not produce a token")
        }
        return token
    }
}
