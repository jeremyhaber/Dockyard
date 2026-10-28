import Foundation
import Crypto

public enum ExportError: Error, Equatable, CustomStringConvertible {
    case notAnExportFile
    case unsupportedVersion(Int)
    case emptyPassphrase
    case wrongPassphrase
    /// The file was modified or damaged after it was written.
    case tampered
    case malformedContents(String)

    public var description: String {
        switch self {
        case .notAnExportFile: "This is not a Dockyard export file"
        case .unsupportedVersion(let v): "This export was made by a newer version of Dockyard (format \(v))"
        case .emptyPassphrase: "A passphrase is required"
        case .wrongPassphrase: "The passphrase is wrong"
        case .tampered: "The file is damaged or has been modified"
        case .malformedContents(let m): "The export contents are unreadable: \(m)"
        }
    }
}

/// One passphrase-protected file with connections, client folders, WHM sources, settings and (optionally) secrets.
///
/// Layout (big endian):
/// ```
/// "DKYDEXP\0"   8 bytes magic
/// version       1 byte  (1)
/// kdf           1 byte  (1 = PBKDF2-HMAC-SHA256)
/// iterations    4 bytes
/// salt         16 bytes (random)
/// nonce        12 bytes (random)
/// verifier     16 bytes HMAC-SHA256(verifyKey, "dockyard-export-verify") truncated
/// ciphertext   n bytes  AES-256-GCM, followed by the 16 byte tag
/// ```
/// 64 bytes are derived from the passphrase: 32 for AES, 32 for the verifier. The whole header is the GCM
/// associated data, so changing any header byte, or any ciphertext byte, fails authentication. The verifier lets a
/// wrong passphrase be told apart from a damaged file.
public enum EncryptedExport {
    public static let defaultIterations = 600_000
    static let magic = Data("DKYDEXP\0".utf8)
    static let headerLength = 8 + 1 + 1 + 4 + 16 + 12 + 16
    static let verifierMessage = Data("dockyard-export-verify".utf8)
    /// Refuse absurd work factors from a hostile file.
    static let maxIterations = 20_000_000

    public struct Header: Sendable, Equatable {
        public var version: Int
        public var iterations: Int
    }

    /// Reads the header of a file without a passphrase. Nil when it is not an export file.
    public static func inspect(_ data: Data) -> Header? {
        guard data.count >= headerLength + 16, data.prefix(magic.count) == magic else { return nil }
        let bytes = [UInt8](data.prefix(headerLength))
        let iterations = bytes[10..<14].reduce(0) { ($0 << 8) | Int($1) }
        return Header(version: Int(bytes[8]), iterations: iterations)
    }

    public static func seal(_ contents: ExportContents, passphrase: String, iterations: Int = defaultIterations) throws -> Data {
        guard !passphrase.isEmpty else { throw ExportError.emptyPassphrase }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(ExportPayload(contents))

        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let nonceBytes = Data((0..<12).map { _ in UInt8.random(in: .min ... .max) })
        let (encryptionKey, verifier) = derive(passphrase, salt: salt, iterations: iterations)

        var header = magic
        header.append(contentsOf: [UInt8(ExportPayload.currentVersion), 1])
        withUnsafeBytes(of: UInt32(iterations).bigEndian) { header.append(contentsOf: $0) }
        header += salt
        header += nonceBytes
        header += verifier

        let box = try AES.GCM.seal(plaintext, using: encryptionKey, nonce: AES.GCM.Nonce(data: nonceBytes), authenticating: header)
        return header + box.ciphertext + box.tag
    }

    public static func open(_ data: Data, passphrase: String) throws -> ExportContents {
        guard let header = inspect(data) else { throw ExportError.notAnExportFile }
        guard header.version <= ExportPayload.currentVersion else { throw ExportError.unsupportedVersion(header.version) }
        guard !passphrase.isEmpty else { throw ExportError.emptyPassphrase }
        let bytes = Data(data)
        guard bytes[bytes.startIndex + 9] == 1, (1...maxIterations).contains(header.iterations) else { throw ExportError.tampered }

        let base = bytes.startIndex
        let salt = bytes[base + 14 ..< base + 30]
        let nonceBytes = bytes[base + 30 ..< base + 42]
        let storedVerifier = bytes[base + 42 ..< base + 58]
        let (encryptionKey, verifier) = derive(passphrase, salt: Data(salt), iterations: header.iterations)
        guard constantTimeEqual(verifier, Data(storedVerifier)) else { throw ExportError.wrongPassphrase }

        let sealed = bytes[(base + headerLength)...]
        let ciphertext = sealed.dropLast(16), tag = sealed.suffix(16)
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceBytes), ciphertext: ciphertext, tag: tag)
            plaintext = try AES.GCM.open(box, using: encryptionKey, authenticating: bytes[base ..< base + headerLength])
        } catch {
            throw ExportError.tampered
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(ExportPayload.self, from: plaintext).contents } catch {
            throw ExportError.malformedContents("\(error)")
        }
    }

    // MARK: Key derivation

    private static func derive(_ passphrase: String, salt: Data, iterations: Int) -> (SymmetricKey, Data) {
        // NFC so the same passphrase typed on different keyboards derives the same key.
        let secret = Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
        let material = PBKDF2.derive(passphrase: secret, salt: salt, iterations: iterations, length: 64)
        let verifyKey = SymmetricKey(data: material.suffix(32))
        let mac = HMAC<SHA256>.authenticationCode(for: verifierMessage, using: verifyKey)
        return (SymmetricKey(data: material.prefix(32)), Data(mac.prefix(16)))
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
