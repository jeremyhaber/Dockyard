import Foundation

public enum SecretPurpose: String, Sendable, Hashable, Codable, CaseIterable {
    case password, keyPassphrase, elevationPassword, cloudToken
}

public protocol SecretStore: Sendable {
    func secret(for connection: UUID, purpose: SecretPurpose) async throws -> String?
    func setSecret(_ secret: String, for connection: UUID, purpose: SecretPurpose) async throws
    func removeSecret(for connection: UUID, purpose: SecretPurpose) async throws
}

public actor InMemorySecretStore: SecretStore {
    private var items: [String: String] = [:]

    public init() {}

    private func key(_ connection: UUID, _ purpose: SecretPurpose) -> String {
        "\(connection.uuidString).\(purpose.rawValue)"
    }

    public func secret(for connection: UUID, purpose: SecretPurpose) -> String? {
        items[key(connection, purpose)]
    }

    public func setSecret(_ secret: String, for connection: UUID, purpose: SecretPurpose) {
        items[key(connection, purpose)] = secret
    }

    public func removeSecret(for connection: UUID, purpose: SecretPurpose) {
        items.removeValue(forKey: key(connection, purpose))
    }
}
