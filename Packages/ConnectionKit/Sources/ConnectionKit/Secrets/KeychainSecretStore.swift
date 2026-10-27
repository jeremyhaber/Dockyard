#if canImport(Security)
import Foundation
import Security

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

/// Generic-password items keyed by `<connection id>.<purpose>` under a fixed service.
/// Pass `accessGroup` to share items with the File Provider extension. The data-protection keychain
/// (needed for access groups on macOS) requires the app to be signed with a keychain-access-groups
/// entitlement; set `useDataProtectionKeychain` to false for unsigned command-line tools.
public struct KeychainSecretStore: SecretStore {
    public static let defaultService = "app.dockyard.mac"

    public let service: String
    public let accessGroup: String?
    public let useDataProtectionKeychain: Bool

    public init(
        service: String = KeychainSecretStore.defaultService,
        accessGroup: String? = nil,
        useDataProtectionKeychain: Bool = true
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    public func secret(for connection: UUID, purpose: SecretPurpose) async throws -> String? {
        var query = baseQuery(connection, purpose)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func setSecret(_ secret: String, for connection: UUID, purpose: SecretPurpose) async throws {
        let data = Data(secret.utf8)
        let query = baseQuery(connection, purpose)

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: updateStatus)
        }
    }

    public func removeSecret(for connection: UUID, purpose: SecretPurpose) async throws {
        let status = SecItemDelete(baseQuery(connection, purpose) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(_ connection: UUID, _ purpose: SecretPurpose) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(connection.uuidString).\(purpose.rawValue)",
        ]
        if useDataProtectionKeychain { query[kSecUseDataProtectionKeychain as String] = true }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}
#endif
