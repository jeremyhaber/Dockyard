import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Splits the control connection stream into text lines (CRLF or LF terminated).
private struct FTPLineDecoder: ByteToMessageDecoder {
    typealias InboundOut = String

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let newline = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else { return .needMoreData }
        let length = newline - buffer.readerIndex
        var line = buffer.readString(length: length) ?? ""
        buffer.moveReaderIndex(forwardBy: 1)
        if line.hasSuffix("\r") { line.removeLast() }
        context.fireChannelRead(wrapInboundOut(line))
        return .continue
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }
}

private final class FTPReplyHandler: ChannelInboundHandler {
    typealias InboundIn = String

    private var parser = FTPReplyParser()
    private let continuation: AsyncThrowingStream<FTPReply, Error>.Continuation
    private let onLine: @Sendable (String) -> Void

    init(continuation: AsyncThrowingStream<FTPReply, Error>.Continuation, onLine: @escaping @Sendable (String) -> Void) {
        self.continuation = continuation
        self.onLine = onLine
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = unwrapInboundIn(data)
        onLine(line)
        if let reply = parser.feed(line) { continuation.yield(reply) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish(throwing: RemoteError.notConnected)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }
}

/// One FTP control connection. Not safe for concurrent commands; `FTPFileSystem` serializes access.
final class FTPControlChannel: @unchecked Sendable {
    let channel: Channel
    private var replies: AsyncThrowingStream<FTPReply, Error>.AsyncIterator
    private let log: LogHub

    private init(channel: Channel, replies: AsyncThrowingStream<FTPReply, Error>, log: LogHub) {
        self.channel = channel
        self.replies = replies.makeAsyncIterator()
        self.log = log
    }

    var isActive: Bool { channel.isActive }

    static func connect(host: String, port: Int, group: EventLoopGroup, log: LogHub) async throws -> FTPControlChannel {
        let (stream, continuation) = AsyncThrowingStream<FTPReply, Error>.makeStream(bufferingPolicy: .unbounded)
        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(15))
            .channelOption(.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(FTPLineDecoder()),
                        FTPReplyHandler(continuation: continuation) { line in log.emit(.response, line) },
                    ])
                }
            }
            .connect(host: host, port: port)
            .get()
        return FTPControlChannel(channel: channel, replies: stream, log: log)
    }

    func readReply() async throws -> FTPReply {
        guard let reply = try await replies.next() else { throw RemoteError.notConnected }
        return reply
    }

    func send(_ command: String) async throws {
        guard !command.contains("\r"), !command.contains("\n") else {
            throw RemoteError.protocolError("Command contains a line break")
        }
        log.emit(.command, LogRedactor.redactFTPCommand(command))
        try await channel.writeAndFlush(channel.allocator.buffer(string: command + "\r\n")).get()
    }

    func command(_ command: String) async throws -> FTPReply {
        try await send(command)
        return try await readReply()
    }

    /// Inserts TLS in front of the existing handlers (after a `234` reply to `AUTH TLS`).
    func startTLS(context: NIOSSLContext, serverHostname: String?) async throws {
        try await channel.eventLoop.submit { [channel] in
            let handler = try NIOSSLClientHandler(context: context, serverHostname: serverHostname)
            try channel.pipeline.syncOperations.addHandler(handler, position: .first)
        }.get()
    }

    func close() async {
        try? await channel.close().get()
    }
}
