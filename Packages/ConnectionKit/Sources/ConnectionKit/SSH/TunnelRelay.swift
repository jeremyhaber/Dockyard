import Foundation

/// The local end handed to the inner session as its transport.
struct TunnelEndpoint: @unchecked Sendable {
    let descriptor: Int32
    let relay: TunnelRelay
}

/// Creates a connected pair of non-blocking local sockets.
func makeSocketPair() throws -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    #if canImport(Darwin)
    let type = SOCK_STREAM
    #else
    let type = Int32(SOCK_STREAM.rawValue)
    #endif
    guard socketpair(AF_UNIX, type, 0, &fds) == 0 else {
        throw RemoteError.protocolError("Cannot create tunnel socket: \(String(cString: strerror(errno)))")
    }
    for fd in fds {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        #if canImport(Darwin)
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }
    return (fds[0], fds[1])
}

/// Pumps bytes between a direct-tcpip channel on the outer session and a local socket that the inner
/// session treats as its TCP connection. libssh2 calls happen on the outer session's queue; waiting
/// for readiness happens here on a dedicated thread so latency stays low.
final class TunnelRelay: @unchecked Sendable {
    private static let highWater = 256 * 1024

    private let session: SSHSession
    private let channel: SSHChannel
    private let descriptor: Int32
    private let lock = NSLock()
    private var stopped = false

    init(session: SSHSession, channel: SSHChannel, descriptor: Int32) {
        self.session = session
        self.channel = channel
        self.descriptor = descriptor
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "app.dockyard.ssh-tunnel"
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run() {
        var toChannel = [UInt8]()
        var toInner = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        var peerClosed = false

        loop: while !isStopped {
            var fds = [
                pollfd(fd: descriptor, events: Int16(POLLIN) | (toInner.isEmpty ? 0 : Int16(POLLOUT)), revents: 0),
                pollfd(fd: session.transportDescriptor, events: Int16(POLLIN), revents: 0),
            ]
            if toChannel.count >= Self.highWater { fds[0].events &= ~Int16(POLLIN) }
            _ = poll(&fds, fds[1].fd >= 0 ? 2 : 1, 50)
            var progressed = false

            // Inner session -> buffer.
            if fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0, toChannel.count < Self.highWater {
                let n = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if n > 0 {
                    toChannel += buffer[0..<n]
                    progressed = true
                } else if n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                    break loop
                }
            }

            // Outer queue: push to the channel, pull from it.
            let pending = toChannel
            let wantsRead = toInner.count < Self.highWater
            let outcome: (written: Int, data: Data?, eof: Bool)? = try? session.queue.sync {
                guard session.isAlive else { throw RemoteError.notConnected }
                var written = 0
                if !pending.isEmpty {
                    try channel.write(pending)
                    written = pending.count
                }
                var data: Data?
                if wantsRead { data = try channel.readNow() }
                return (written, data, channel.isEOF && data == nil)
            }
            guard let outcome else { break loop }
            if outcome.written > 0 {
                toChannel.removeFirst(outcome.written)
                progressed = true
            }
            if let data = outcome.data {
                toInner += data
                progressed = true
            }
            peerClosed = outcome.eof

            // Buffer -> inner session.
            if !toInner.isEmpty {
                let n = toInner.withUnsafeBytes { sendNoSignal(descriptor, $0.baseAddress, $0.count) }
                if n > 0 {
                    toInner.removeFirst(n)
                    progressed = true
                } else if n < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                    break loop
                }
            }
            if peerClosed && toInner.isEmpty { break loop }
            if !progressed { usleep(500) }
        }

        _ = close(descriptor)
        session.queue.sync { channel.close() }
    }
}

private func sendNoSignal(_ fd: Int32, _ pointer: UnsafeRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
    return write(fd, pointer, count)
    #else
    return send(fd, pointer, count, Int32(MSG_NOSIGNAL))
    #endif
}
