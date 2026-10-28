import ConnectionKit
import Foundation

public struct RcloneRPCError: Error, Equatable, CustomStringConvertible {
    public var method: String
    public var status: Int
    public var message: String

    public var description: String { "\(method) failed (\(status)): \(message)" }
}

/// Typed access to rc calls with secret-free logging.
public struct RcloneClient: Sendable {
    public typealias Logger = @Sendable (LogLine.Kind, String) -> Void

    public let transport: any RcloneTransport
    private let logger: Logger?

    public init(transport: any RcloneTransport, logger: Logger? = nil) {
        self.transport = transport
        self.logger = logger
    }

    public func withLogger(_ logger: @escaping Logger) -> RcloneClient {
        RcloneClient(transport: transport, logger: logger)
    }

    @discardableResult
    public func call(_ method: String, _ params: [String: JSONValue] = [:], quiet: Bool = false) async throws -> Data {
        if !quiet { logger?(.command, RcloneRedactor.describe(method: method, params: params)) }
        let input = String(decoding: try JSONEncoder().encode(params), as: UTF8.self)
        let response = await transport.perform(method: method, input: input)
        let data = Data(response.output.utf8)
        guard response.status == 200 else {
            struct Failure: Decodable { var error: String? }
            let raw = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? response.output
            let error = RcloneRPCError(method: method, status: response.status, message: RcloneRedactor.redact(raw))
            if !quiet { logger?(.error, error.description) }
            throw error
        }
        return data
    }

    public func call<T: Decodable>(
        _ method: String,
        _ params: [String: JSONValue] = [:],
        as type: T.Type,
        quiet: Bool = false
    ) async throws -> T {
        let data = try await call(method, params, quiet: quiet)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RemoteError.protocolError("Unexpected rclone response to \(method): \(error)")
        }
    }
}
