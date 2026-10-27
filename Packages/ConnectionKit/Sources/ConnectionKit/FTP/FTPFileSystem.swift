import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// FTP and explicit FTPS (`AUTH TLS`) on SwiftNIO. One instance owns one control connection and
/// runs commands one at a time; the connection is re-established transparently if it drops.
public actor FTPFileSystem: RemoteFileSystem {
    public struct Options: Sendable {
        /// Set to false to accept self-signed certificates (FTPS only).
        public var verifyCertificate = true
        public var preferEPSV = true

        public init(verifyCertificate: Bool = true, preferEPSV: Bool = true) {
            self.verifyCertificate = verifyCertificate
            self.preferEPSV = preferEPSV
        }
    }

    public nonisolated let config: ConnectionConfig
    private let secrets: SecretStore
    private var options: Options
    private let group: EventLoopGroup
    private let hub = LogHub()
    private let lock = AsyncLock()

    private var control: FTPControlChannel?
    private var shouldReconnect = false
    private var tlsContext: NIOSSLContext?
    private var supportsMLST = false
    private var listUsesAllFlag = true

    public nonisolated var logStream: AsyncStream<LogLine> { hub.stream() }
    public nonisolated var supportsShell: Bool { false }

    public init(
        config: ConnectionConfig,
        secrets: SecretStore,
        options: Options = Options(),
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.config = config
        self.secrets = secrets
        self.options = options
        self.group = group
    }

    // MARK: Connection

    public func connect() async throws {
        try await lock.withLock {
            shouldReconnect = true
            do {
                try await establish()
            } catch {
                hub.emit(.error, "Connection failed: \(error)")
                await dropControl()
                throw error
            }
        }
    }

    public func disconnect() async {
        await lock.withLock {
            shouldReconnect = false
            if let control, control.isActive {
                _ = try? await control.command("QUIT")
            }
            await dropControl()
            hub.emit(.status, "Disconnected")
        }
    }

    private func establish() async throws {
        await dropControl()
        hub.emit(.status, "Connecting to \(config.host):\(config.port)...")
        let control = try await FTPControlChannel.connect(host: config.host, port: config.port, group: group, log: hub)
        self.control = control
        hub.emit(.status, "Connection established, waiting for welcome message...")

        let greeting: FTPReply
        do { greeting = try await control.readReply() } catch RemoteError.notConnected {
            throw RemoteError.connectionRefused("The server closed the connection before sending a greeting")
        }
        guard greeting.isCompletion else {
            throw RemoteError.ftpRefusal(code: greeting.code, message: greeting.message)
                ?? RemoteError.serverRejected(code: greeting.code, message: greeting.message)
        }

        if config.protocol == .ftps {
            _ = try check(try await control.command("AUTH TLS"), "AUTH TLS", { $0.code == 234 })
            try await control.startTLS(context: try makeTLSContext(), serverHostname: tlsServerName)
            _ = try check(try await control.command("PBSZ 0"), "PBSZ", { $0.isCompletion })
            _ = try check(try await control.command("PROT P"), "PROT", { $0.isCompletion })
            hub.emit(.status, "TLS connection established")
        }

        try await login(control)
        hub.emit(.status, "Logged in as \(config.username.isEmpty ? "anonymous" : config.username)")

        let features = try await control.command("FEAT")
        if features.isCompletion {
            let lines = features.lines.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            supportsMLST = lines.contains { $0.hasPrefix("MLST") }
            if lines.contains("UTF8") { _ = try await control.command("OPTS UTF8 ON") }
        } else {
            supportsMLST = false
        }
        _ = try check(try await control.command("TYPE I"), "TYPE I", { $0.isCompletion })
    }

    private func login(_ control: FTPControlChannel) async throws {
        let anonymous = config.username.isEmpty
        let user = anonymous ? "anonymous" : config.username
        let password: String
        if anonymous {
            password = "anonymous@"
        } else if let stored = try await secrets.secret(for: config.id, purpose: .password) {
            password = stored
        } else {
            throw RemoteError.authenticationFailed("No password stored for this connection")
        }

        var reply = try await control.command("USER \(user)")
        if reply.isIntermediate {
            reply = try await control.command("PASS \(password)")
        }
        guard reply.isCompletion else {
            if let refusal = RemoteError.ftpRefusal(code: reply.code, message: reply.message) { throw refusal }
            if reply.code == 530 { throw RemoteError.authenticationFailed(reply.message) }
            throw RemoteError.serverRejected(code: reply.code, message: reply.message)
        }
    }

    private func dropControl() async {
        let old = control
        control = nil
        await old?.close()
    }

    /// Returns the live control channel, reconnecting if the server dropped us.
    private func activeControl() async throws -> FTPControlChannel {
        if let control, control.isActive { return control }
        guard shouldReconnect else { throw RemoteError.notConnected }
        hub.emit(.status, "Connection lost, reconnecting...")
        try await establish()
        guard let control else { throw RemoteError.notConnected }
        return control
    }

    private var tlsServerName: String? {
        (try? SocketAddress(ipAddress: config.host, port: 0)) == nil ? config.host : nil
    }

    private func makeTLSContext() throws -> NIOSSLContext {
        if let tlsContext { return tlsContext }
        var configuration = TLSConfiguration.makeClientConfiguration()
        if !options.verifyCertificate { configuration.certificateVerification = .none }
        let context = try NIOSSLContext(configuration: configuration)
        tlsContext = context
        return context
    }

    // MARK: Helpers

    @discardableResult
    private func check(_ reply: FTPReply, _ what: String, _ accept: (FTPReply) -> Bool) throws -> FTPReply {
        guard accept(reply) else {
            if reply.code == 530 { throw RemoteError.authenticationFailed(reply.message) }
            throw RemoteError.serverRejected(code: reply.code, message: reply.message)
        }
        return reply
    }

    private func sizeOf(_ path: String, on control: FTPControlChannel) async throws -> UInt64? {
        let reply = try await control.command("SIZE \(path)")
        guard reply.code == 213 else { return nil }
        return UInt64(reply.message.trimmingCharacters(in: .whitespaces))
    }

    /// Negotiates a passive data connection (EPSV first, then PASV) and connects to it.
    /// For FTPS, `handshake` completes once the TLS handshake with the server has finished.
    private func openDataChannel(on control: FTPControlChannel) async throws -> (channel: Channel, handshake: EventLoopFuture<Void>?) {
        var endpoint: FTPPassive.Endpoint?
        if options.preferEPSV {
            let reply = try await control.command("EPSV")
            if reply.code == 229 {
                endpoint = FTPPassive.parseEPSV(reply.message)
            } else if reply.isFailure {
                options.preferEPSV = false
            }
        }
        if endpoint == nil {
            let reply = try await control.command("PASV")
            guard reply.code == 227, let parsed = FTPPassive.parsePASV(reply.message) else {
                throw RemoteError.serverRejected(code: reply.code, message: reply.message)
            }
            endpoint = parsed
        }
        guard let endpoint else { throw RemoteError.protocolError("No passive endpoint") }

        var host = config.host
        if let reported = endpoint.host, !FTPPassive.isNonRoutable(reported) || FTPPassive.isNonRoutable(config.host) {
            host = reported
        }

        let tls: (NIOSSLContext, String?)? = config.protocol == .ftps ? (try makeTLSContext(), tlsServerName) : nil
        let handshake = LockedBox<EventLoopFuture<Void>?>(nil)
        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(15))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let (context, name) = tls {
                        let promise = channel.eventLoop.makePromise(of: Void.self)
                        handshake.withLock { $0 = promise.futureResult }
                        try channel.pipeline.syncOperations.addHandlers([
                            try NIOSSLClientHandler(context: context, serverHostname: name),
                            TLSHandshakeWatcher(promise: promise),
                        ])
                    }
                }
            }
            .connect(host: host, port: endpoint.port)
            .get()
        return (channel, handshake.withLock { $0 })
    }

    private func closeData(_ channel: Channel) async {
        // TLS shutdown waits for the peer's close_notify and reports `uncleanShutdown` if it never comes.
        try? await channel.close()
    }

    private func asyncWrapped(_ channel: Channel) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        try await channel.eventLoop.submit {
            try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
        }.get()
    }

    private static func validate(path: String) throws {
        guard !path.contains("\n"), !path.contains("\r") else {
            throw RemoteError.invalidConfiguration("Path contains a line break")
        }
    }

    // MARK: Listing

    public func homeDirectory() async throws -> String {
        try await lock.withLock {
            let control = try await activeControl()
            let reply = try check(try await control.command("PWD"), "PWD", { $0.code == 257 })
            let text = reply.message
            guard let first = text.firstIndex(of: "\""), let last = text.lastIndex(of: "\""), first < last else { return "/" }
            return text[text.index(after: first)..<last].replacingOccurrences(of: "\"\"", with: "\"")
        }
    }

    public func list(_ path: String) async throws -> [RemoteItem] {
        try Self.validate(path: path)
        return try await lock.withLock {
            try await listLocked(path, on: try await activeControl())
        }
    }

    /// Callers must hold `lock`.
    private func listLocked(_ path: String, on control: FTPControlChannel) async throws -> [RemoteItem] {
        if supportsMLST {
            do {
                let lines = try await retrieveListing("MLSD \(path)", on: control)
                return lines.compactMap { FTPListParser.parseMLSD($0, parent: path) }
            } catch RemoteError.serverRejected(let code, _) where [500, 501, 502, 504].contains(code) {
                supportsMLST = false
            }
        }
        return try await listWithLIST(path, on: control)
    }

    private func listWithLIST(_ path: String, on control: FTPControlChannel) async throws -> [RemoteItem] {
        var lines: [String]
        if listUsesAllFlag {
            do {
                lines = try await retrieveListing("LIST -a \(path)", on: control)
            } catch RemoteError.serverRejected(let code, _) where [500, 501, 502, 504].contains(code) {
                listUsesAllFlag = false
                lines = try await retrieveListing("LIST \(path)", on: control)
            }
        } else {
            lines = try await retrieveListing("LIST \(path)", on: control)
        }
        let now = Date()
        return lines.compactMap { FTPListParser.parseUnixList($0, parent: path, now: now) }
            .filter { $0.name != "." && $0.name != ".." }
    }

    private func retrieveListing(_ command: String, on control: FTPControlChannel) async throws -> [String] {
        let (channel, _) = try await openDataChannel(on: control)
        let async = try await asyncWrapped(channel)
        var data = Data()
        try await async.executeThenClose { inbound, _ in
            let start = try await control.command(command)
            guard start.isPreliminary else { throw RemoteError.serverRejected(code: start.code, message: start.message) }
            do {
                for try await var chunk in inbound {
                    data.append(contentsOf: chunk.readBytes(length: chunk.readableBytes) ?? [])
                }
            } catch NIOSSLError.uncleanShutdown {}
        }
        _ = try check(try await control.readReply(), command, { $0.isCompletion })
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    // MARK: Transfers

    public func download(_ remote: String, to local: URL, progress: Progress, resume: Bool) async throws {
        try Self.validate(path: remote)
        try await lock.withLock {
            let control = try await activeControl()
            let total = try await sizeOf(remote, on: control)
            var offset: UInt64 = 0
            if resume, let existing = LocalFile.size(of: local), existing > 0 {
                if let total, existing == total {
                    progress.totalUnitCount = Int64(total)
                    progress.completedUnitCount = Int64(total)
                    hub.emit(.status, "File \(local.lastPathComponent) already complete")
                    return
                }
                if total == nil || existing < total! { offset = existing }
            }
            if offset == 0 { _ = FileManager.default.createFile(atPath: local.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: local)
            defer { try? handle.close() }

            progress.totalUnitCount = Int64(total ?? 0)
            hub.emit(.status, "Starting download of \(remote)\(offset > 0 ? " from offset \(offset)" : "")")

            let (channel, _) = try await openDataChannel(on: control)
            let async = try await asyncWrapped(channel)
            var transferStarted = false
            do {
                try await async.executeThenClose { inbound, _ in
                    if offset > 0 {
                        let rest = try await control.command("REST \(offset)")
                        if !rest.isIntermediate {
                            hub.emit(.warning, "Server cannot resume; restarting download from the beginning")
                            offset = 0
                        }
                    }
                    try handle.truncate(atOffset: offset)
                    try handle.seek(toOffset: offset)
                    progress.completedUnitCount = Int64(offset)

                    let start = try await control.command("RETR \(remote)")
                    guard start.isPreliminary else { throw RemoteError.serverRejected(code: start.code, message: start.message) }
                    transferStarted = true
                    do {
                        for try await var chunk in inbound {
                            try Task.checkCancellation()
                            if progress.isCancelled { throw CancellationError() }
                            let bytes = chunk.readBytes(length: chunk.readableBytes) ?? []
                            try handle.write(contentsOf: bytes)
                            progress.completedUnitCount += Int64(bytes.count)
                        }
                    } catch NIOSSLError.uncleanShutdown {}
                }
            } catch {
                if transferStarted { await dropControl() }
                hub.emit(.error, "Download of \(remote) failed: \(error)")
                throw error
            }
            _ = try check(try await control.readReply(), "RETR", { $0.isCompletion })
            hub.emit(.status, "Download of \(remote) finished")
        }
    }

    public func upload(_ local: URL, to remote: String, progress: Progress, resume: Bool) async throws {
        try Self.validate(path: remote)
        guard let total = LocalFile.size(of: local) else {
            throw RemoteError.notFound(local.path)
        }
        try await lock.withLock {
            let control = try await activeControl()
            var offset: UInt64 = 0
            if resume, let existing = try await sizeOf(remote, on: control), existing > 0 {
                if existing == total {
                    progress.totalUnitCount = Int64(total)
                    progress.completedUnitCount = Int64(total)
                    hub.emit(.status, "File \(remote) already complete")
                    return
                }
                if existing < total { offset = existing }
            }
            let handle = try FileHandle(forReadingFrom: local)
            defer { try? handle.close() }
            progress.totalUnitCount = Int64(total)
            hub.emit(.status, "Starting upload of \(remote)\(offset > 0 ? " from offset \(offset)" : "")")

            let (channel, handshake) = try await openDataChannel(on: control)
            if offset > 0 {
                let rest = try await control.command("REST \(offset)")
                if !rest.isIntermediate {
                    hub.emit(.warning, "Server cannot resume; restarting upload from the beginning")
                    offset = 0
                }
            }
            try handle.seek(toOffset: offset)
            progress.completedUnitCount = Int64(offset)

            let start: FTPReply
            do {
                start = try await control.command("STOR \(remote)")
            } catch {
                await closeData(channel)
                throw error
            }
            guard start.isPreliminary else {
                await closeData(channel)
                throw RemoteError.serverRejected(code: start.code, message: start.message)
            }

            do {
                try await handshake?.get()
                while let chunk = try handle.read(upToCount: LocalFile.chunkSize), !chunk.isEmpty {
                    try Task.checkCancellation()
                    if progress.isCancelled { throw CancellationError() }
                    try await channel.writeAndFlush(ByteBuffer(bytes: chunk)).get()
                    progress.completedUnitCount += Int64(chunk.count)
                }
                await closeData(channel)
            } catch {
                await closeData(channel)
                await dropControl()
                hub.emit(.error, "Upload of \(remote) failed: \(error)")
                throw error
            }
            _ = try check(try await control.readReply(), "STOR", { $0.isCompletion })
            hub.emit(.status, "Upload of \(remote) finished")
        }
    }

    // MARK: Namespace operations

    public func mkdir(_ path: String) async throws {
        try Self.validate(path: path)
        try await lock.withLock {
            let control = try await activeControl()
            try check(try await control.command("MKD \(path)"), "MKD", { $0.isCompletion })
        }
    }

    public func rename(_ from: String, _ to: String) async throws {
        try Self.validate(path: from)
        try Self.validate(path: to)
        try await lock.withLock {
            let control = try await activeControl()
            try check(try await control.command("RNFR \(from)"), "RNFR", { $0.isIntermediate })
            try check(try await control.command("RNTO \(to)"), "RNTO", { $0.isCompletion })
        }
    }

    public func delete(_ path: String, recursive: Bool) async throws {
        try Self.validate(path: path)
        try await lock.withLock {
            let control = try await activeControl()
            let name = RemotePath.lastComponent(of: path)
            let siblings = path == "/" ? [] : try await listLocked(RemotePath.parent(of: path), on: control)
            guard let item = siblings.first(where: { $0.name == name }) else { throw RemoteError.notFound(path) }
            try await remove(item, recursive: recursive, on: control)
        }
    }

    private func remove(_ item: RemoteItem, recursive: Bool, on control: FTPControlChannel) async throws {
        if item.isDirectory {
            if recursive {
                for child in try await listLocked(item.path, on: control) { try await remove(child, recursive: true, on: control) }
            }
            try check(try await control.command("RMD \(item.path)"), "RMD", { $0.isCompletion })
        } else {
            try check(try await control.command("DELE \(item.path)"), "DELE", { $0.isCompletion })
        }
    }

    public func chmod(_ path: String, mode: UInt16) async throws {
        try Self.validate(path: path)
        try await lock.withLock {
            let control = try await activeControl()
            let octal = String(mode & 0o7777, radix: 8)
            let reply = try await control.command("SITE CHMOD \(octal) \(path)")
            if [500, 501, 502, 504].contains(reply.code) {
                hub.emit(.warning, "Server does not support SITE CHMOD; ignored")
                return
            }
            try check(reply, "SITE CHMOD", { $0.isCompletion })
        }
    }
}

private final class TLSHandshakeWatcher: ChannelInboundHandler {
    typealias InboundIn = NIOAny

    private let promise: EventLoopPromise<Void>
    private var finished = false

    init(promise: EventLoopPromise<Void>) { self.promise = promise }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        promise.completeWith(result)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event { finish(.success(())) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error))
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.failure(RemoteError.notConnected))
        context.fireChannelInactive()
    }
}
