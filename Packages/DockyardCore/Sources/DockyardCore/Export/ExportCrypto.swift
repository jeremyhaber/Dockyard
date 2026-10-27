import Foundation
import Crypto

/// PBKDF2-HMAC-SHA256 (RFC 8018) on swift-crypto's incremental SHA-256, so each iteration costs two
/// hash finalisations and no key setup.
enum PBKDF2 {
    static func derive(passphrase: Data, salt: Data, iterations: Int, length: Int) -> Data {
        precondition(iterations > 0 && length > 0)
        let blockSize = 64
        var key = passphrase
        if key.count > blockSize { key = Data(SHA256.hash(data: key)) }
        key.append(Data(repeating: 0, count: blockSize - key.count))

        var inner = SHA256()
        inner.update(data: key.map { $0 ^ 0x36 })
        var outer = SHA256()
        outer.update(data: key.map { $0 ^ 0x5c })

        func hmac(_ message: Data) -> [UInt8] {
            var i = inner
            i.update(data: message)
            var o = outer
            o.update(data: Data(i.finalize()))
            return Array(o.finalize())
        }

        var output = Data()
        var block: UInt32 = 1
        while output.count < length {
            var index = Data(); withUnsafeBytes(of: block.bigEndian) { index.append(contentsOf: $0) }
            var u = hmac(salt + index)
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    var i = inner
                    u.withUnsafeBytes { i.update(bufferPointer: $0) }
                    var o = outer
                    i.finalize().withUnsafeBytes { o.update(bufferPointer: $0) }
                    u = Array(o.finalize())
                    for k in 0..<t.count { t[k] ^= u[k] }
                }
            }
            output.append(contentsOf: t)
            block += 1
        }
        return output.prefix(length)
    }
}
