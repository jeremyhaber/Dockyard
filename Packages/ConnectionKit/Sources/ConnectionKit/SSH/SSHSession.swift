#if canImport(CSSH)
import CSSH
#else
import CLibSSH2
#endif
import Foundation

private let libssh2Ready: Bool = libssh2_init(0) == 0

/// One SSH connection (libssh2). libssh2 is blocking and not thread safe per session, so every
/// call runs on this session's private serial queue, in non-blocking mode with `poll` waits.
/// Channels share the session; `perform` is the only way in from async code.
public final class SSHSession: @unchecked Sendable {
    let queue = DispatchQueue(label: "app.dockyard.ssh-session")
    let options: SSHSessionOptions
    let log: @Sendable (LogLine.Kind, String) -> Void

    // Everything below is confined to `queue`.
    var handle: OpaquePointer?
    private var socketFD: Int32 = -1
    /// The session this one is tunnelled through (jump host). Closed together with this session.
    private var upstream: SSHSession?
    private var relay: TunnelRelay?
    private var channels: [ObjectIdentifier: SSHChannel] = [:]
    private var shells: [ObjectIdentifier: ShellChannel] = [:]
    private var pumpScheduled = false
    private var keepAliveTimer: DispatchSourceTimer?
    private(set) var isAlive = false
    private var lastFailureCode: Int32 = 0

    private init(options: SSHSessionOptions, log: @escaping @Sendable (LogLine.Kind, String) -> Void) {
        self.options = options
        self.log = log
    }

    deinit {
        // `close()` normally ran already; this only releases what a dropped session still holds.
        keepAliveTimer?.cancel()
        if let handle { libssh2_session_free(handle) }
        if socketFD >= 0 { closeSocket(socketFD) }
    }

    // MARK: Connecting

    /// Opens the TCP connection, performs the SSH handshake and asks `validator` about the host key.
    /// Nothing secret has been sent when the validator runs.
    /// With `via`, the connection runs through a direct-tcpip channel of that (already authenticated)
    /// session. The new session then owns `via` and closes it when it closes; on failure `via` stays open.
    public static func connect(
        host: String,
        port: Int,
        via upstream: SSHSession? = nil,
        options: SSHSessionOptions = SSHSessionOptions(),
        validator: SSHHostKeyValidator = .acceptAnything(),
        log: @escaping @Sendable (LogLine.Kind, String) -> Void = { _, _ in }
    ) async throws -> SSHSession {
        guard libssh2Ready else { throw RemoteError.protocolError("libssh2 failed to initialise") }
        let session = SSHSession(options: options, log: log)
        let hostKey: SSHHostKey
        do {
            if let upstream {
                let tunnel = try await upstream.openTunnel(to: host, port: port)
                session.adopt(tunnel, upstream: upstream)
                hostKey = try await session.perform(requireAlive: false) { try $0.establish(socket: tunnel.descriptor) }
            } else {
                hostKey = try await session.perform(requireAlive: false) {
                    try $0.establish(socket: try tcpConnect(host: host, port: port, timeout: options.connectTimeout))
                }
            }
        } catch {
            let refusal = try? await session.perform(requireAlive: false) { $0.refusal(for: error) }
            session.upstream = nil
            await session.close()
            throw refusal ?? error
        }
        log(.status, "Host key \(hostKey.algorithm) \(hostKey.fingerprint)")
        guard await validator.validate(hostKey) else {
            session.upstream = nil
            await session.close()
            throw RemoteError.hostKeyRejected(hostKey.fingerprint)
        }
        return session
    }

    /// Whether the transport is still up (false after a keepalive or socket failure).
    var alive: Bool {
        get async { await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.isAlive) } } }
    }

    /// Runs `body` on the session queue. libssh2 calls are only legal in here.
    func perform<T: Sendable>(requireAlive: Bool = true, _ body: @escaping @Sendable (SSHSession) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.isAlive || !requireAlive else { return continuation.resume(throwing: RemoteError.notConnected) }
                continuation.resume(with: Result { try body(self) })
            }
        }
    }

    private func establish(socket: Int32) throws -> SSHHostKey {
        socketFD = socket
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw RemoteError.protocolError("Cannot create SSH session")
        }
        handle = session
        isAlive = true
        libssh2_session_set_blocking(session, 0)
        let fd = socketFD
        try call("SSH handshake", timeout: options.connectTimeout) { libssh2_session_handshake(session, fd) }

        if let banner = libssh2_session_banner_get(session) { log(.status, "Server: \(String(cString: banner))") }
        if options.keepAliveInterval > 0 { startKeepAlive() }
        return try readHostKey(session)
    }

    private func readHostKey(_ session: OpaquePointer) throws -> SSHHostKey {
        var length = 0
        var type: Int32 = 0
        guard let raw = libssh2_session_hostkey(session, &length, &type) else {
            throw RemoteError.protocolError("Server sent no host key")
        }
        let blob = Data(bytes: raw, count: length)
        guard let hash = libssh2_hostkey_hash(session, Int32(LIBSSH2_HOSTKEY_HASH_SHA256)) else {
            throw RemoteError.protocolError("Cannot hash the host key")
        }
        let digest = Data(bytes: hash, count: 32)
        let algorithm: String
        switch type {
        case Int32(LIBSSH2_HOSTKEY_TYPE_RSA): algorithm = "ssh-rsa"
        case Int32(LIBSSH2_HOSTKEY_TYPE_DSS): algorithm = "ssh-dss"
        case Int32(LIBSSH2_HOSTKEY_TYPE_ECDSA_256): algorithm = "ecdsa-sha2-nistp256"
        case Int32(LIBSSH2_HOSTKEY_TYPE_ECDSA_384): algorithm = "ecdsa-sha2-nistp384"
        case Int32(LIBSSH2_HOSTKEY_TYPE_ECDSA_521): algorithm = "ecdsa-sha2-nistp521"
        case Int32(LIBSSH2_HOSTKEY_TYPE_ED25519): algorithm = "ssh-ed25519"
        default: algorithm = "unknown"
        }
        let base64 = digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
        return SSHHostKey(algorithm: algorithm, fingerprint: "SHA256:" + base64, key: blob)
    }

    // MARK: Authentication

    /// Tries `steps` in order on this connection until the server reports success.
    public func authenticate(username: String, steps: [SSHAuthStep]) async throws {
        do { try await authenticateSteps(username: username, steps: steps) } catch {
            throw (try? await perform(requireAlive: false) { $0.refusal(for: error) }) ?? error
        }
    }

    private func authenticateSteps(username: String, steps: [SSHAuthStep]) async throws {
        let log = self.log
        try await perform { session in
            guard let handle = session.handle else { throw RemoteError.notConnected }
            if let methods = try session.offeredAuthMethods(handle, username: username) {
                if methods.isEmpty { log(.status, "Server accepted login without authentication"); return }
                log(.status, "Server offers: \(methods)")
            }
            var failures: [String] = []
            for (index, step) in steps.enumerated() {
                log(.status, "Authenticating as \(username) using \(step)")
                let outcome = try session.runAuthStep(step, handle: handle, username: username)
                if libssh2_userauth_authenticated(handle) != 0 {
                    log(.status, "Authenticated with \(step)")
                    return
                }
                failures.append(outcome)
                if let next = steps.dropFirst(index + 1).first {
                    let name = "\(step)"
                    log(.status, "\(name.prefix(1).uppercased() + name.dropFirst()) authentication rejected; trying \(next)")
                }
            }
            throw RemoteError.authenticationFailed(failures.isEmpty ? "No authentication method available" : failures.joined(separator: "; "))
        }
    }

    /// The server's comma separated method list, or nil when it could not be read.
    private func offeredAuthMethods(_ handle: OpaquePointer, username: String) throws -> String? {
        let deadline = deadline(options.operationTimeout)
        while true {
            if let list = libssh2_userauth_list(handle, username, UInt32(username.utf8.count)) {
                return String(cString: list)
            }
            let code = libssh2_session_last_errno(handle)
            if libssh2_userauth_authenticated(handle) != 0 { return "" }
            if code == LIBSSH2_ERROR_EAGAIN { try waitForSocket(until: deadline, what: "authentication"); continue }
            return nil
        }
    }

    /// Returns a short failure reason; success is checked by the caller through `userauth_authenticated`.
    private func runAuthStep(_ step: SSHAuthStep, handle: OpaquePointer, username: String) throws -> String {
        let userLength = UInt32(username.utf8.count)
        let code: Int32
        switch step {
        case .password(let password):
            code = try callRaw("password authentication") {
                libssh2_userauth_password_ex(handle, username, userLength, password, UInt32(password.utf8.count), nil)
            }
        case .publicKey(let key, let passphrase):
            code = try callRaw("public key authentication") {
                key.withCString { privateKey in
                    libssh2_userauth_publickey_frommemory(
                        handle, username, Int(userLength), nil, 0, privateKey, key.utf8.count, passphrase
                    )
                }
            }
            if code == LIBSSH2_ERROR_FILE || code == LIBSSH2_ERROR_INVAL {
                return "Cannot use the private key (wrong passphrase or unsupported format)"
            }
        case .keyboardInteractive(let responder):
            code = try keyboardInteractive(handle, username: username, responder: responder)
        case .agent:
            code = try agentAuth(handle, username: username, socketPath: nil)
        case .agentSocket(let path):
            code = try agentAuth(handle, username: username, socketPath: path)
        }
        return code == 0 ? "" : "\(step) rejected"
    }

    private func keyboardInteractive(_ handle: OpaquePointer, username: String, responder: @escaping SSHPromptResponder) throws -> Int32 {
        let context = Unmanaged.passRetained(KeyboardInteractiveContext(responder: responder))
        let abstract = libssh2_session_abstract(handle)
        abstract?.pointee = context.toOpaque()
        defer {
            abstract?.pointee = nil
            context.release()
        }
        return try callRaw("keyboard-interactive authentication") {
            libssh2_userauth_keyboard_interactive_ex(handle, username, UInt32(username.utf8.count), keyboardInteractiveCallback)
        }
    }

    private func agentAuth(_ handle: OpaquePointer, username: String, socketPath: String?) throws -> Int32 {
        guard let agent = libssh2_agent_init(handle) else { throw RemoteError.protocolError("Cannot create agent handle") }
        defer {
            libssh2_agent_disconnect(agent)
            libssh2_agent_free(agent)
        }
        if let socketPath { libssh2_agent_set_identity_path(agent, socketPath) }
        guard libssh2_agent_connect(agent) == 0 else {
            log(.warning, socketPath.map { "Cannot connect to ssh-agent at \($0)" } ?? "Cannot connect to ssh-agent (is SSH_AUTH_SOCK set?)")
            return LIBSSH2_ERROR_AUTHENTICATION_FAILED
        }
        guard libssh2_agent_list_identities(agent) == 0 else {
            log(.warning, "Cannot list ssh-agent identities")
            return LIBSSH2_ERROR_AUTHENTICATION_FAILED
        }
        var previous: UnsafeMutablePointer<libssh2_agent_publickey>?
        var tried = 0
        while true {
            var identity: UnsafeMutablePointer<libssh2_agent_publickey>?
            guard libssh2_agent_get_identity(agent, &identity, previous) == 0, let identity else { break }
            previous = identity
            tried += 1
            let code = try callRaw("agent authentication") { libssh2_agent_userauth(agent, username, identity) }
            if code == 0 { return 0 }
        }
        if tried == 0 { log(.warning, "ssh-agent holds no identities") }
        return LIBSSH2_ERROR_AUTHENTICATION_FAILED
    }

    // MARK: Channels

    func newChannel() throws -> SSHChannel {
        guard let handle else { throw RemoteError.notConnected }
        let deadline = deadline(options.operationTimeout)
        while true {
            if let raw = libssh2_channel_open_ex(handle, "session", 7, 4 * 1024 * 1024, 32768, nil, 0) {
                let channel = SSHChannel(session: self, handle: raw)
                channels[ObjectIdentifier(channel)] = channel
                return channel
            }
            let code = libssh2_session_last_errno(handle)
            if code == LIBSSH2_ERROR_EAGAIN { try waitForSocket(until: deadline, what: "open channel"); continue }
            throw failure("open channel", code)
        }
    }

    func newDirectTCPIPChannel(host: String, port: Int) throws -> SSHChannel {
        guard let handle else { throw RemoteError.notConnected }
        let deadline = deadline(options.operationTimeout)
        while true {
            if let raw = libssh2_channel_direct_tcpip_ex(handle, host, Int32(port), "127.0.0.1", 0) {
                let channel = SSHChannel(session: self, handle: raw)
                channels[ObjectIdentifier(channel)] = channel
                return channel
            }
            let code = libssh2_session_last_errno(handle)
            if code == LIBSSH2_ERROR_EAGAIN { try waitForSocket(until: deadline, what: "open tunnel"); continue }
            throw failure("open tunnel to \(host):\(port)", code)
        }
    }

    /// Opens a direct-tcpip channel to `host:port` as seen from this session's server and bridges it
    /// to a local socket that another libssh2 session can use as its transport.
    func openTunnel(to host: String, port: Int) async throws -> TunnelEndpoint {
        let channel = try await perform { try $0.newDirectTCPIPChannel(host: host, port: port) }
        do {
            let (inner, outer) = try makeSocketPair()
            let relay = TunnelRelay(session: self, channel: channel, descriptor: outer)
            relay.start()
            return TunnelEndpoint(descriptor: inner, relay: relay)
        } catch {
            try? await perform { _ in channel.close() }
            throw error
        }
    }

    func adopt(_ tunnel: TunnelEndpoint, upstream: SSHSession) {
        self.upstream = upstream
        self.relay = tunnel.relay
        queue.sync { socketFD = tunnel.descriptor }
    }

    /// The socket libssh2 polls; constant after the handshake began.
    var transportDescriptor: Int32 { socketFD }

    func release(_ channel: SSHChannel) {
        channels.removeValue(forKey: ObjectIdentifier(channel))
        shells.removeValue(forKey: ObjectIdentifier(channel))
    }

    /// Runs a command to completion and collects its output.
    public func exec(_ command: String, stdin: Data? = nil) async throws -> SSHExecResult {
        let channel = try await perform { session in
            let channel = try session.newChannel()
            try channel.exec(command)
            return channel
        }
        do {
            if let stdin { try await perform { _ in try channel.write(stdin) } }
            try await perform { _ in try channel.sendEOF() }
            var stdout = Data(), stderr = Data()
            while true {
                let chunk = try await perform { _ in try channel.readSome(wait: 0.2) }
                stdout.append(chunk.stdout)
                stderr.append(chunk.stderr)
                if chunk.isEOF { break }
            }
            let status = try await perform { _ in try channel.closeAndExitStatus() }
            return SSHExecResult(stdout: stdout, stderr: stderr, exitStatus: status)
        } catch {
            try? await perform { _ in channel.close() }
            throw error
        }
    }

    /// Opens an interactive PTY shell on this connection. With `elevation`, `su -` or `sudo -i` is typed
    /// and its password prompt answered without showing the password. With `runAs` (a root login), the shell
    /// switches to that user instead.
    public func openShell(cols: Int, rows: Int, elevation: ShellElevation? = nil, runAs: String? = nil) async throws -> ShellChannel {
        if let runAs, !Self.isValidAccountName(runAs) {
            throw RemoteError.invalidConfiguration("\"\(runAs)\" is not a valid account name")
        }
        return try await perform { session in
            let channel = try session.newChannel()
            do {
                try channel.requestPTY(cols: cols, rows: rows)
                try channel.startShell()
            } catch {
                channel.close()
                throw error
            }
            let shell = ShellChannel(session: session, channel: channel, elevation: elevation, runAs: runAs)
            session.shells[ObjectIdentifier(channel)] = shell
            session.schedulePump(after: 0.005)
            return shell
        }
    }

    // MARK: Pumping shells and keepalive

    func schedulePump(after delay: TimeInterval) {
        guard !pumpScheduled, !shells.isEmpty else { return }
        pumpScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            pumpScheduled = false
            guard isAlive else { return }
            var active = false
            for shell in Array(shells.values) { active = shell.pump() || active }
            schedulePump(after: active ? 0.002 : 0.02)
        }
    }

    private func startKeepAlive() {
        guard let handle else { return }
        libssh2_keepalive_config(handle, 1, UInt32(options.keepAliveInterval))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [self] in
            guard isAlive, let handle = self.handle else { return }
            var next: Int32 = 0
            let rc = libssh2_keepalive_send(handle, &next)
            if rc != 0 && rc != LIBSSH2_ERROR_EAGAIN {
                log(.warning, "Keepalive failed; connection lost")
                isAlive = false
                for shell in Array(shells.values) { shell.finish() }
            }
        }
        timer.resume()
        keepAliveTimer = timer
    }

    // MARK: Closing

    public func close() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.shutdown()
                continuation.resume()
            }
        }
        relay?.stop()
        relay = nil
        let parent = upstream
        upstream = nil
        await parent?.close()
    }

    private func shutdown() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        for shell in Array(shells.values) { shell.finish() }
        shells.removeAll()
        for channel in Array(channels.values) { channel.free() }
        channels.removeAll()
        if let handle {
            if isAlive {
                let deadline = deadline(2)
                while libssh2_session_disconnect_ex(handle, 11, "Disconnected by user", "") == LIBSSH2_ERROR_EAGAIN {
                    if (try? waitForSocket(until: deadline, what: "disconnect")) == nil { break }
                }
            }
            libssh2_session_free(handle)
        }
        handle = nil
        isAlive = false
        if socketFD >= 0 { closeSocket(socketFD) }
        socketFD = -1
    }

    // MARK: Waiting and error mapping

    func deadline(_ seconds: TimeInterval) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
    }

    /// Waits (at most 20 ms per call) for the socket direction libssh2 is blocked on.
    func waitForSocket(until deadline: UInt64, what: String) throws {
        guard let handle, socketFD >= 0 else { throw RemoteError.notConnected }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw RemoteError.protocolError("\(what): timed out")
        }
        let directions = libssh2_session_block_directions(handle)
        var events: Int16 = 0
        if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { events |= Int16(POLLIN) }
        if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { events |= Int16(POLLOUT) }
        var descriptor = pollfd(fd: socketFD, events: events == 0 ? Int16(POLLIN) : events, revents: 0)
        _ = poll(&descriptor, 1, 20)
    }

    /// Repeats `body` while libssh2 reports EAGAIN; throws on other negative codes.
    @discardableResult
    func call(_ what: String, timeout: TimeInterval? = nil, _ body: () -> Int32) throws -> Int32 {
        let code = try callRaw(what, timeout: timeout, body)
        if code < 0 { throw failure(what, code) }
        return code
    }

    /// Like `call` but returns negative codes (authentication rejections) instead of throwing,
    /// except for transport failures.
    func callRaw(_ what: String, timeout: TimeInterval? = nil, _ body: () -> Int32) throws -> Int32 {
        let limit = deadline(timeout ?? options.operationTimeout)
        while true {
            let code = body()
            if code == LIBSSH2_ERROR_EAGAIN { try waitForSocket(until: limit, what: what); continue }
            if code < 0, isTransportFailure(code) { throw failure(what, code) }
            return code
        }
    }

    private func isTransportFailure(_ code: Int32) -> Bool {
        [LIBSSH2_ERROR_SOCKET_DISCONNECT, LIBSSH2_ERROR_SOCKET_SEND, LIBSSH2_ERROR_SOCKET_RECV,
         LIBSSH2_ERROR_SOCKET_TIMEOUT, LIBSSH2_ERROR_SOCKET_NONE, LIBSSH2_ERROR_BANNER_RECV,
         LIBSSH2_ERROR_KEX_FAILURE, LIBSSH2_ERROR_TIMEOUT].contains(code)
    }

    /// A server that drops us while connecting or logging in is limiting connections (sshd `MaxStartups`,
    /// fail2ban, per-IP limits), which is a refusal rather than a broken session.
    func refusal(for error: Error) -> RemoteError? {
        guard case RemoteError.protocolError(let message) = error else { return nil }
        let codes = [LIBSSH2_ERROR_SOCKET_DISCONNECT, LIBSSH2_ERROR_BANNER_RECV, LIBSSH2_ERROR_SOCKET_RECV, LIBSSH2_ERROR_KEX_FAILURE]
        guard codes.contains(lastFailureCode) || RemoteError.looksLikeConnectionLimit(message) else { return nil }
        return .connectionRefused(message)
    }

    func failure(_ what: String, _ code: Int32) -> RemoteError {
        lastFailureCode = code
        var message: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        if let handle { _ = libssh2_session_last_error(handle, &message, &length, 0) }
        let text = message.map { String(cString: $0) } ?? "error \(code)"
        if isTransportFailure(code) { isAlive = false }
        return .protocolError("\(what): \(text)")
    }
}

// MARK: - Keyboard-interactive callback

private final class KeyboardInteractiveContext {
    let responder: SSHPromptResponder
    init(responder: @escaping SSHPromptResponder) { self.responder = responder }
}

private let keyboardInteractiveCallback: @convention(c) (
    UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, Int32, Int32,
    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
    UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Void = { _, _, _, _, count, prompts, responses, abstract in
    guard let raw = abstract?.pointee, let prompts, let responses else { return }
    let context = Unmanaged<KeyboardInteractiveContext>.fromOpaque(raw).takeUnretainedValue()
    for index in 0..<Int(count) {
        let prompt = prompts[index]
        let text = prompt.text.map { String(decoding: UnsafeBufferPointer(start: $0, count: prompt.length), as: UTF8.self) } ?? ""
        let answer = context.responder(text, prompt.echo != 0)
        responses[index].text = strdup(answer)
        responses[index].length = UInt32(answer.utf8.count)
    }
}

// MARK: - TCP

@inline(__always) private func closeSocket(_ fd: Int32) { _ = close(fd) }

private func tcpConnect(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    #if canImport(Darwin)
    hints.ai_socktype = SOCK_STREAM
    #else
    hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    #endif
    var results: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, String(port), &hints, &results)
    guard status == 0, let first = results else {
        throw RemoteError.protocolError("Cannot resolve \(host): \(String(cString: gai_strerror(status)))")
    }
    defer { freeaddrinfo(results) }

    var lastError = "connection failed"
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let info = cursor {
        cursor = info.pointee.ai_next
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if fd < 0 { continue }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var yes: Int32 = 1
        _ = setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var rc = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if rc != 0 && errno == EINPROGRESS {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&descriptor, 1, Int32(timeout * 1000)) > 0 {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                rc = error == 0 ? 0 : -1
                errno = error
            } else {
                errno = ETIMEDOUT
                rc = -1
            }
        }
        if rc == 0 { return fd }
        lastError = String(cString: strerror(errno))
        closeSocket(fd)
    }
    throw RemoteError.protocolError("Cannot connect to \(host):\(port): \(lastError)")
}
