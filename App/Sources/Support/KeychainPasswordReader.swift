import DockyardCore
import Foundation
#if canImport(Security)
import Security
#endif

/// Reads the password another app saved as an internet-password Keychain item. macOS asks the user to allow
/// access to items Dockyard did not create; declining (or no match) returns nil and the connection asks on first connect.
struct KeychainPasswordReader: ImportedPasswordReader {
    func password(for request: KeychainPasswordRequest) async -> String? {
        #if canImport(Security)
        await withCheckedContinuation { continuation in
            // SecItemCopyMatching blocks while the system prompt is on screen.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.lookup(request))
            }
        }
        #else
        nil
        #endif
    }

    #if canImport(Security)
    /// Narrowest query first: server, account, port and protocol, then without the protocol and port, which apps record inconsistently.
    static func lookup(_ request: KeychainPasswordRequest) -> String? {
        var attempts: [[String: Any]] = []
        var exact = base(request)
        if let port = request.port { exact[kSecAttrPort as String] = port }
        if let proto = protocolAttribute(request.protocolName) {
            attempts.append(exact.merging([kSecAttrProtocol as String: proto]) { $1 })
        }
        attempts.append(exact)
        attempts.append(base(request))
        for query in attempts {
            var full = query
            full[kSecReturnData as String] = true
            full[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(full as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
                  let text = String(data: data, encoding: .utf8), !text.isEmpty else { continue }
            return text
        }
        return nil
    }

    private static func base(_ request: KeychainPasswordRequest) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: request.server,
            kSecAttrAccount as String: request.account,
        ]
    }

    private static func protocolAttribute(_ name: String?) -> CFString? {
        switch name?.lowercased() {
        case "sftp", "ssh": kSecAttrProtocolSSH
        case "ftp": kSecAttrProtocolFTP
        case "ftps", "ftp-tls", "ftpes", "ftp-ssl": kSecAttrProtocolFTPS
        default: nil
        }
    }
    #endif
}
