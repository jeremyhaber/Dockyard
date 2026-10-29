import Foundation

/// A minimal SFTP v3 client over any SSH channel (the `sftp` subsystem, or `sftp-server` started
/// through sudo/su on an exec channel). Requests carry ids and responses are routed by id, so
/// several operations, including pipelined transfers, can share the channel.
///
/// The synchronous methods must run on the session queue; use `run` from async code.
final class SFTPClient: @unchecked Sendable {
    let session: SSHSession
    private let channel: SSHChannel

    private var buffer: [UInt8]
    private var bufferStart = 0
    private var nextID: UInt32 = 1
    private var parked: [UInt32: SFTPResponse] = [:]
    private var abandoned: Set<UInt32> = []
    /// Set when the channel failed or the server stopped answering.
    private var isBroken = false

    /// False once the server closed the channel or it failed; the client cannot be used again.
    var isOpen: Bool { !isBroken && !channel.isEOF }

    /// `prefill` holds bytes already read from the channel past a start-up marker.
    init(session: SSHSession, channel: SSHChannel, prefill: [UInt8] = []) {
        self.session = session
        self.channel = channel
        buffer = prefill
    }

    func run<T: Sendable>(_ body: @escaping @Sendable (SFTPClient) throws -> T) async throws -> T {
        try await session.perform { _ in try body(self) }
    }

    func handshake() throws {
        var writer = SFTPWriter(type: SFTPType.initialize)
        writer.u32(3)
        try channel.write(writer.packet())
        guard let packet = try readPacket(blocking: true), packet.first == SFTPType.version else {
            throw RemoteError.protocolError("Server did not answer the SFTP handshake")
        }
    }

    func close() { channel.close() }

    // MARK: Transport

    private func readPacket(blocking: Bool) throws -> [UInt8]? {
        var limit = session.deadline(session.options.operationTimeout)
        while true {
            let available = buffer.count - bufferStart
            if available >= 4 {
                let length = buffer[bufferStart..<bufferStart + 4].reduce(0) { $0 << 8 | Int($1) }
                guard length <= 16 * 1024 * 1024 else { throw RemoteError.protocolError("SFTP packet too large") }
                if available >= 4 + length {
                    let packet = Array(buffer[bufferStart + 4..<bufferStart + 4 + length])
                    bufferStart += 4 + length
                    if bufferStart == buffer.count {
                        buffer.removeAll(keepingCapacity: true)
                        bufferStart = 0
                    } else if bufferStart > 1 << 20 {
                        buffer.removeFirst(bufferStart)
                        bufferStart = 0
                    }
                    return packet
                }
            }
            if let data = try channel.readNow() {
                buffer.append(contentsOf: data)
                limit = session.deadline(session.options.operationTimeout)
                continue
            }
            if channel.isEOF {
                isBroken = true
                throw RemoteError.protocolError("SFTP connection closed by the server")
            }
            guard blocking else { return nil }
            do {
                try session.waitForSocket(until: limit, what: "SFTP")
            } catch {
                // A reply that never comes means the network dropped us without a reset (sleep, Wi-Fi change, NAT
                // timeout). Waiting again on the same socket would hang every later action the same way.
                isBroken = true
                session.dropTransport("SFTP stopped answering")
                throw error
            }
        }
    }

    /// Reads one response and files it under its id. Returns false when nothing is buffered (non-blocking).
    private func receive(blocking: Bool) throws -> Bool {
        guard let packet = try readPacket(blocking: blocking) else { return false }
        let (id, response) = try SFTPReader.response(packet[...])
        if abandoned.remove(id) == nil { parked[id] = response }
        return true
    }

    func submit(_ type: UInt8, _ build: (inout SFTPWriter) -> Void) throws -> UInt32 {
        let id = nextID
        nextID &+= 1
        var writer = SFTPWriter(type: type)
        writer.u32(id)
        build(&writer)
        do { try channel.write(writer.packet()) } catch {
            isBroken = true
            throw error
        }
        return id
    }

    /// Returns the responses for `ids` that have arrived. With `waitForOne`, blocks until at least one has.
    func collect(_ ids: some Collection<UInt32>, waitForOne: Bool) throws -> [(id: UInt32, response: SFTPResponse)] {
        var out: [(UInt32, SFTPResponse)] = []
        func harvest() {
            for id in ids { if let response = parked.removeValue(forKey: id) { out.append((id, response)) } }
        }
        harvest()
        while out.isEmpty && waitForOne { _ = try receive(blocking: true); harvest() }
        while try receive(blocking: false) {}
        harvest()
        return out
    }

    /// Drops responses to requests nobody waits for any more (cancelled transfers).
    func abandon(_ ids: some Collection<UInt32>) {
        for id in ids where parked.removeValue(forKey: id) == nil { abandoned.insert(id) }
    }

    private func roundTrip(_ type: UInt8, _ build: (inout SFTPWriter) -> Void) throws -> SFTPResponse {
        let id = try submit(type, build)
        return try collect([id], waitForOne: true)[0].response
    }

    // MARK: Operations

    private func expectOK(_ response: SFTPResponse) throws {
        guard case .status(let code, let message) = response else { throw RemoteError.protocolError("Unexpected SFTP response") }
        guard code == 0 else { throw SFTPStatusError(code: code, message: message) }
    }

    func expectHandle(_ response: SFTPResponse) throws -> Data {
        if case .handle(let handle) = response { return handle }
        try expectOK(response)
        throw RemoteError.protocolError("Expected an SFTP handle")
    }

    func expectAttributes(_ response: SFTPResponse) throws -> SFTPAttributes {
        if case .attributes(let attrs) = response { return attrs }
        try expectOK(response)
        throw RemoteError.protocolError("Expected SFTP attributes")
    }

    func realpath(_ path: String) throws -> String {
        let response = try roundTrip(SFTPType.realpath) { $0.string(path) }
        guard case .names(let names) = response, let first = names.first else {
            try expectOK(response)
            throw RemoteError.protocolError("Expected an SFTP name")
        }
        return first.name
    }

    func stat(_ path: String, followLinks: Bool) throws -> SFTPAttributes {
        try expectAttributes(roundTrip(followLinks ? SFTPType.stat : SFTPType.lstat) { $0.string(path) })
    }

    func fstat(_ handle: Data) throws -> SFTPAttributes {
        try expectAttributes(roundTrip(SFTPType.fstat) { $0.string(handle) })
    }

    func setstat(_ path: String, _ attributes: SFTPAttributes) throws {
        try expectOK(roundTrip(SFTPType.setstat) { $0.string(path); $0.attributes(attributes) })
    }

    func open(_ path: String, _ flags: SFTPOpenFlags) throws -> Data {
        try expectHandle(roundTrip(SFTPType.open) { $0.string(path); $0.u32(flags.rawValue); $0.attributes(SFTPAttributes()) })
    }

    func closeHandle(_ handle: Data) throws {
        try expectOK(roundTrip(SFTPType.close) { $0.string(handle) })
    }

    func mkdir(_ path: String) throws {
        try expectOK(roundTrip(SFTPType.mkdir) { $0.string(path); $0.attributes(SFTPAttributes()) })
    }

    func rmdir(_ path: String) throws { try expectOK(roundTrip(SFTPType.rmdir) { $0.string(path) }) }
    func remove(_ path: String) throws { try expectOK(roundTrip(SFTPType.remove) { $0.string(path) }) }

    func rename(_ from: String, _ to: String) throws {
        try expectOK(roundTrip(SFTPType.rename) { $0.string(from); $0.string(to) })
    }

    func readlink(_ path: String) throws -> String {
        let response = try roundTrip(SFTPType.readlink) { $0.string(path) }
        guard case .names(let names) = response, let first = names.first else {
            try expectOK(response)
            throw RemoteError.protocolError("Expected an SFTP name")
        }
        return first.name
    }

    /// All entries of a directory except `.` and `..`, with lstat-style attributes.
    func listDirectory(_ path: String) throws -> [SFTPEntry] {
        let handle = try expectHandle(roundTrip(SFTPType.opendir) { $0.string(path) })
        defer { try? closeHandle(handle) }
        var entries: [SFTPEntry] = []
        while true {
            let response = try roundTrip(SFTPType.readdir) { $0.string(handle) }
            if case .names(let batch) = response {
                entries.append(contentsOf: batch.filter { $0.name != "." && $0.name != ".." })
            } else if case .status(let code, _) = response, code == SFTPStatusError.Code.eof.rawValue {
                return entries
            } else {
                try expectOK(response)
                throw RemoteError.protocolError("Unexpected SFTP response to readdir")
            }
        }
    }
}
