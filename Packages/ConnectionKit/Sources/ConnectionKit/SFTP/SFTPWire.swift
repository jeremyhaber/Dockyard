import Foundation

/// SFTP version 3 packet encoding (draft-ietf-secsh-filexfer-02), as spoken by OpenSSH's sftp-server.
enum SFTPType {
    static let initialize: UInt8 = 1, version: UInt8 = 2
    static let open: UInt8 = 3, close: UInt8 = 4, read: UInt8 = 5, write: UInt8 = 6
    static let lstat: UInt8 = 7, fstat: UInt8 = 8, setstat: UInt8 = 9
    static let opendir: UInt8 = 11, readdir: UInt8 = 12, remove: UInt8 = 13, mkdir: UInt8 = 14, rmdir: UInt8 = 15
    static let realpath: UInt8 = 16, stat: UInt8 = 17, rename: UInt8 = 18, readlink: UInt8 = 19
    static let status: UInt8 = 101, handle: UInt8 = 102, data: UInt8 = 103, name: UInt8 = 104, attrs: UInt8 = 105
}

struct SFTPOpenFlags: OptionSet {
    let rawValue: UInt32
    static let read = SFTPOpenFlags(rawValue: 0x01)
    static let write = SFTPOpenFlags(rawValue: 0x02)
    static let create = SFTPOpenFlags(rawValue: 0x08)
    static let truncate = SFTPOpenFlags(rawValue: 0x10)
}

struct SFTPAttributes: Sendable, Equatable {
    var size: UInt64?
    var permissions: UInt32?
    var accessTime: UInt32?
    var modifiedTime: UInt32?

    static let typeMask: UInt32 = 0o170000
    var isDirectory: Bool { permissions.map { $0 & Self.typeMask == 0o040000 } ?? false }
    var isSymlink: Bool { permissions.map { $0 & Self.typeMask == 0o120000 } ?? false }
    var modified: Date? { modifiedTime.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

struct SFTPEntry: Sendable {
    var name: String
    var attributes: SFTPAttributes
}

struct SFTPStatusError: Error, Sendable {
    enum Code: UInt32 { case ok = 0, eof, noSuchFile, permissionDenied, failure, badMessage, noConnection, connectionLost, unsupported }
    var code: UInt32
    var message: String

    var known: Code? { Code(rawValue: code) }
}

enum SFTPResponse: Sendable {
    case status(code: UInt32, message: String)
    case handle(Data)
    case data(Data)
    case names([SFTPEntry])
    case attributes(SFTPAttributes)
}

struct SFTPWriter {
    private(set) var bytes: [UInt8] = [0, 0, 0, 0]

    init(type: UInt8) { bytes.append(type) }

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) } }
    mutating func string(_ value: String) { string(Array(value.utf8)) }
    mutating func string(_ value: Data) { u32(UInt32(value.count)); bytes.append(contentsOf: value) }
    mutating func string(_ value: [UInt8]) { u32(UInt32(value.count)); bytes.append(contentsOf: value) }

    mutating func attributes(_ attrs: SFTPAttributes) {
        var flags: UInt32 = 0
        if attrs.size != nil { flags |= 0x1 }
        if attrs.permissions != nil { flags |= 0x4 }
        if attrs.accessTime != nil, attrs.modifiedTime != nil { flags |= 0x8 }
        u32(flags)
        if let size = attrs.size { u64(size) }
        if let permissions = attrs.permissions { u32(permissions) }
        if let atime = attrs.accessTime, let mtime = attrs.modifiedTime { u32(atime); u32(mtime) }
    }

    /// The finished packet with its length prefix.
    func packet() -> [UInt8] {
        var out = bytes
        let length = UInt32(out.count - 4).bigEndian
        withUnsafeBytes(of: length) { out.replaceSubrange(0..<4, with: $0) }
        return out
    }
}

struct SFTPReader {
    let bytes: ArraySlice<UInt8>
    private var position: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        position = bytes.startIndex
    }

    var isAtEnd: Bool { position >= bytes.endIndex }
    var remaining: ArraySlice<UInt8> { bytes[position...] }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, position + count <= bytes.endIndex else { throw RemoteError.protocolError("Truncated SFTP packet") }
        defer { position += count }
        return bytes[position..<position + count]
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func u32() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func u64() throws -> UInt64 { try take(8).reduce(0) { $0 << 8 | UInt64($1) } }
    mutating func data() throws -> Data { Data(try take(Int(try u32()))) }
    mutating func string() throws -> String { String(decoding: try take(Int(try u32())), as: UTF8.self) }

    mutating func attributes() throws -> SFTPAttributes {
        let flags = try u32()
        var attrs = SFTPAttributes()
        if flags & 0x1 != 0 { attrs.size = try u64() }
        if flags & 0x2 != 0 { _ = try u32(); _ = try u32() }
        if flags & 0x4 != 0 { attrs.permissions = try u32() }
        if flags & 0x8 != 0 { attrs.accessTime = try u32(); attrs.modifiedTime = try u32() }
        if flags & 0x8000_0000 != 0 {
            for _ in 0..<(try u32()) { _ = try data(); _ = try data() }
        }
        return attrs
    }

    /// Parses the body of a response packet (after the length prefix) into its request id and payload.
    static func response(_ packet: ArraySlice<UInt8>) throws -> (id: UInt32, response: SFTPResponse) {
        var reader = SFTPReader(packet)
        let type = try reader.u8()
        let id = try reader.u32()
        switch type {
        case SFTPType.status:
            let code = try reader.u32()
            let message = reader.isAtEnd ? "" : try reader.string()
            return (id, .status(code: code, message: message))
        case SFTPType.handle: return (id, .handle(try reader.data()))
        case SFTPType.data: return (id, .data(try reader.data()))
        case SFTPType.name:
            var entries: [SFTPEntry] = []
            for _ in 0..<(try reader.u32()) {
                let name = try reader.string()
                _ = try reader.string()
                entries.append(SFTPEntry(name: name, attributes: try reader.attributes()))
            }
            return (id, .names(entries))
        case SFTPType.attrs: return (id, .attributes(try reader.attributes()))
        default: throw RemoteError.protocolError("Unexpected SFTP packet type \(type)")
        }
    }
}
