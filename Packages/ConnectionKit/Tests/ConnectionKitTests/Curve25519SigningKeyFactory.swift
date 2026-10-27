import Crypto
import Foundation

/// Builds an unencrypted OpenSSH-format Ed25519 private key for tests.
enum Curve25519SigningKeyFactory {
    static func makeOpenSSHPrivateKey() -> String {
        let key = Curve25519.Signing.PrivateKey()
        let pub = Array(key.publicKey.rawRepresentation)
        let seed = Array(key.rawRepresentation)

        func string(_ bytes: [UInt8]) -> [UInt8] {
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { Array($0) } + bytes
        }
        let type = string(Array("ssh-ed25519".utf8))
        let publicBlob = string(type + string(pub))
        let check = withUnsafeBytes(of: UInt32.random(in: 0...UInt32.max).bigEndian) { Array($0) }
        var privateBlob = check + check + type + string(pub) + string(seed + pub) + string([])
        var pad: UInt8 = 1
        while privateBlob.count % 8 != 0 { privateBlob.append(pad); pad += 1 }

        let blob = Array("openssh-key-v1\0".utf8)
            + string(Array("none".utf8)) + string(Array("none".utf8)) + string([])
            + withUnsafeBytes(of: UInt32(1).bigEndian) { Array($0) }
            + publicBlob + string(privateBlob)
        let base64 = Data(blob).base64EncodedString()
        let wrapped = stride(from: 0, to: base64.count, by: 70).map { i -> String in
            let start = base64.index(base64.startIndex, offsetBy: i)
            return String(base64[start..<base64.index(start, offsetBy: min(70, base64.count - i))])
        }
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n" + wrapped.joined(separator: "\n") + "\n-----END OPENSSH PRIVATE KEY-----\n"
    }
}
