import Citadel
import Crypto
import Foundation

/// Citadel and swift-crypto key/client types are not `Sendable`; the SFTP actor is their only user.
struct Boxed<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// One authentication attempt on its own connection.
///
/// Citadel's `SSHAuthenticationMethod` offers exactly one credential per connection and its custom
/// delegate hook is single-shot, so "key, then password" is implemented as two connection attempts.
struct SSHAuthAttempt: Sendable {
    let label: String
    let method: @Sendable (_ username: String) -> SSHAuthenticationMethod

    static func password(_ password: String) -> SSHAuthAttempt {
        SSHAuthAttempt(label: "password") { .passwordBased(username: $0, password: password) }
    }

    /// Loads an OpenSSH-format Ed25519 or RSA private key.
    static func key(path: String, passphrase: String?) throws -> SSHAuthAttempt {
        let expanded = (path as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            throw RemoteError.invalidConfiguration("Cannot read key file at \(path)")
        }
        let decryptionKey = passphrase.map { Data($0.utf8) }
        let type: SSHKeyType
        do {
            type = try SSHKeyDetection.detectPrivateKeyType(from: text)
        } catch {
            throw RemoteError.unsupported("Only OpenSSH-format private keys are supported (convert with `ssh-keygen -p -f <key>`)")
        }
        do {
            switch type {
            case .ed25519:
                let key = Boxed(try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: decryptionKey))
                return SSHAuthAttempt(label: "public key") { .ed25519(username: $0, privateKey: key.value) }
            case .rsa:
                let key = Boxed(try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: decryptionKey))
                return SSHAuthAttempt(label: "public key") { .rsa(username: $0, privateKey: key.value) }
            default:
                throw RemoteError.unsupported("\(type) keys are not supported yet")
            }
        } catch let error as RemoteError {
            throw error
        } catch {
            throw RemoteError.authenticationFailed("Cannot decrypt private key (wrong passphrase?)")
        }
    }

    static func isRejection(_ error: Error) -> Bool {
        guard let error = error as? SSHClientError else { return false }
        switch error {
        case .allAuthenticationOptionsFailed, .unsupportedPasswordAuthentication,
             .unsupportedPrivateKeyAuthentication, .unsupportedHostBasedAuthentication:
            return true
        case .channelCreationFailed:
            return false
        }
    }
}
