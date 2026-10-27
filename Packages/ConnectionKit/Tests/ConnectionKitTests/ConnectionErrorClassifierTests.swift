import Foundation
import NIOCore
import Testing
@testable import ConnectionKit

@Suite struct ConnectionErrorClassifierTests {
    private func kind(_ error: any Error) -> ConnectionErrorKind { ConnectionErrorClassifier.classify(error) }

    @Test func remoteErrors() {
        #expect(kind(RemoteError.authenticationFailed("Authentication failed")) == .authenticationFailed)
        #expect(kind(RemoteError.authenticationFailed("Too many authentication failures")) == .refused)
        #expect(kind(RemoteError.hostKeyRejected("SHA256:abc")) == .hostKeyRejected)
        #expect(kind(RemoteError.connectionRefused("limit")) == .refused)
        #expect(kind(RemoteError.serverRejected(code: 530, message: "Login incorrect")) == .authenticationFailed)
        #expect(kind(RemoteError.serverRejected(code: 421, message: "Service not available")) == .refused)
        #expect(kind(RemoteError.serverRejected(code: 550, message: "No such file")) == .other)
        #expect(kind(RemoteError.invalidConfiguration("Cannot read key file")) == .other)
        #expect(kind(RemoteError.notFound("/x")) == .other)
    }

    @Test func protocolErrorText() {
        #expect(kind(RemoteError.protocolError("Cannot resolve nope.invalid: Name or service not known")) == .hostNotFound)
        #expect(kind(RemoteError.protocolError("Cannot resolve h: nodename nor servname provided, or not known")) == .hostNotFound)
        #expect(kind(RemoteError.protocolError("Cannot connect to h:22: Connection refused")) == .refused)
        #expect(kind(RemoteError.protocolError("Cannot connect to h:22: Operation timed out")) == .timedOut)
        #expect(kind(RemoteError.protocolError("SSH handshake: timed out")) == .timedOut)
        #expect(kind(RemoteError.protocolError("Something else")) == .other)
    }

    @Test func nioErrors() {
        #expect(kind(ChannelError.connectTimeout(.seconds(15))) == .timedOut)
        #expect(kind(ChannelError.eof) == .other)
        #expect(kind(IOError(errnoCode: ECONNREFUSED, reason: "connect")) == .refused)
        #expect(kind(IOError(errnoCode: ETIMEDOUT, reason: "connect")) == .timedOut)
        #expect(kind(IOError(errnoCode: EPIPE, reason: "write")) == .other)
    }

    @Test func foundationErrors() {
        #expect(kind(URLError(.cannotFindHost)) == .hostNotFound)
        #expect(kind(URLError(.timedOut)) == .timedOut)
        #expect(kind(URLError(.cannotConnectToHost)) == .refused)
        #expect(kind(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))) == .refused)
        #expect(kind(CancellationError()) == .other)
    }
}
