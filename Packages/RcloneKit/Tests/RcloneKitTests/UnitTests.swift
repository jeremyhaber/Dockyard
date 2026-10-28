import ConnectionKit
import Foundation
import Testing
@testable import RcloneKit

final class FakeTransport: RcloneTransport {
    typealias Handler = @Sendable (String, [String: JSONValue]) -> RcloneResponse
    private let handler: Handler
    private let recorded = LockedBox<[(method: String, params: [String: JSONValue])]>([])

    init(_ handler: @escaping Handler = { _, _ in RcloneResponse(status: 200, output: "{}") }) {
        self.handler = handler
    }

    var calls: [(method: String, params: [String: JSONValue])] { recorded.withLock { $0 } }

    func perform(method: String, input: String) async -> RcloneResponse {
        let params = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(input.utf8))) ?? [:]
        recorded.withLock { $0.append((method, params)) }
        return handler(method, params)
    }
}

private func ok(_ json: String) -> RcloneResponse { RcloneResponse(status: 200, output: json) }

private func s3Spec(root: String = "") -> RcloneRemoteSpec {
    RcloneRemoteSpec(backend: .s3, options: ["provider": S3Provider.minio], root: root)
}

private func connectedFS(
    spec: RcloneRemoteSpec = s3Spec(),
    transport: FakeTransport
) async throws -> RcloneFileSystem {
    let config = ConnectionConfig(protocol: .rclone, host: "localhost:9000", username: "AK")
    let secrets = InMemorySecretStore()
    await secrets.setSecret("SK", for: config.id, purpose: .cloudToken)
    let fs = RcloneFileSystem(config: config, spec: spec, secrets: secrets, transport: transport)
    try await fs.connect()
    return fs
}

@Suite struct ConnectionStringTests {
    @Test func s3() throws {
        let remote = try s3Spec(root: "/bucket/dir/").resolve(username: "AK", host: "localhost:9000", secret: "SK")
        #expect(remote.fs == ":s3,access_key_id=AK,endpoint=\"https://localhost:9000\",env_auth=false,provider=Minio,secret_access_key=SK:bucket/dir")
        #expect(remote.redactedFs.contains("secret_access_key=****"))
        #expect(!remote.redactedFs.contains("SK"))
    }

    @Test func explicitEndpointWinsOverHost() throws {
        var spec = s3Spec()
        spec.options["endpoint"] = "http://127.0.0.1:9000"
        let remote = try spec.resolve(username: "AK", host: "ignored.example", secret: "SK")
        #expect(remote.fs.contains("endpoint=\"http://127.0.0.1:9000\""))
        #expect(!remote.fs.contains("ignored"))
    }

    @Test func anonymousS3() throws {
        let remote = try s3Spec().resolve(username: "", host: "", secret: nil)
        #expect(remote.fs == ":s3,env_auth=false,provider=Minio:")
    }

    @Test func halfS3CredentialsAreRejected() {
        #expect(throws: RemoteError.self) { try s3Spec().resolve(username: "AK", host: "", secret: nil) }
        #expect(throws: RemoteError.self) { try s3Spec().resolve(username: "", host: "", secret: "SK") }
    }

    @Test func b2() throws {
        let spec = RcloneRemoteSpec(backend: .b2, root: "bucket")
        let remote = try spec.resolve(username: "acct", host: "", secret: "appkey")
        #expect(remote.fs == ":b2,account=acct,key=appkey:bucket")
        #expect(remote.redactedFs == ":b2,account=acct,key=****:bucket")
        #expect(throws: RemoteError.self) { try spec.resolve(username: "acct", host: "", secret: nil) }
    }

    @Test func oauthTokenIsQuotedAndMasked() throws {
        let token = #"{"access_token":"a,b:c","refresh_token":"r","expiry":"2030-01-01T00:00:00Z"}"#
        let spec = RcloneRemoteSpec(backend: .drive, options: ["client_id": "cid", "client_secret": "csecret"])
        let remote = try spec.resolve(username: "", host: "", secret: token)
        #expect(remote.fs.contains(#"token="{""access_token"":""a,b:c"""#))
        #expect(!remote.redactedFs.contains("a,b:c"))
        #expect(!remote.redactedFs.contains("csecret"))
        #expect(remote.redactedFs.contains("client_id=cid"))
    }

    @Test func invalidOAuthTokenIsRejected() {
        let spec = RcloneRemoteSpec(backend: .dropbox)
        #expect(throws: RemoteError.self) { try spec.resolve(username: "", host: "", secret: "not json") }
        #expect(throws: RemoteError.self) { try spec.resolve(username: "", host: "", secret: nil) }
        #expect(throws: RemoteError.self) { try spec.resolve(username: "", host: "", secret: "{}") }
    }

    @Test func quoting() {
        #expect(RcloneRemoteSpec.quote("plain-1.2_x/y") == "plain-1.2_x/y")
        #expect(RcloneRemoteSpec.quote("a b") == "\"a b\"")
        #expect(RcloneRemoteSpec.quote("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(RcloneRemoteSpec.quote("") == "\"\"")
    }
}

@Suite struct RedactionTests {
    @Test func masksSecretsInConnectionStrings() {
        let line = ":s3,access_key_id=AK,secret_access_key=SK,session_token=\"a,b\":bucket"
        let out = RcloneRedactor.redact(line)
        #expect(out == ":s3,access_key_id=AK,secret_access_key=****,session_token=****:bucket")
    }

    @Test func masksQuotedTokenWithEscapes() {
        let out = RcloneRedactor.redact(#":drive,token="{""access_token"":""x""}",client_id=c:"#)
        #expect(out == ":drive,token=****,client_id=c:")
    }

    @Test func leavesPlainTextAlone() {
        #expect(RcloneRedactor.redact("monkey=1 downloading file") == "monkey=1 downloading file")
    }

    @Test func describeNeverShowsSecrets() {
        let line = RcloneRedactor.describe(method: "config/create", params: [
            "fs": "::s3,secret_access_key=SK:b", "token": "T", "parameters": ["token": "T2"], "_async": true,
        ])
        #expect(!line.contains("SK") && !line.contains("T2") && !line.contains("=T"))
        #expect(line.hasPrefix("rc config/create"))
        #expect(!line.contains("_async"))
    }

    @Test func rpcErrorsAreRedacted() async {
        let transport = FakeTransport { _, _ in
            RcloneResponse(status: 500, output: #"{"error":"bad key secret_access_key=SK here"}"#)
        }
        do {
            try await RcloneClient(transport: transport).call("x")
            Issue.record("expected failure")
        } catch let error as RcloneRPCError {
            #expect(error.status == 500)
            #expect(!error.message.contains("SK"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Suite struct DecodingTests {
    @Test func listEntries() throws {
        let json = """
        {"list":[
          {"Path":"a.txt","Name":"a.txt","Size":12,"MimeType":"text/plain","ModTime":"2024-05-06T07:08:09.123456789Z","IsDir":false},
          {"Path":"sub","Name":"sub","Size":-1,"MimeType":"inode/directory","ModTime":"2024-05-06T07:08:09Z","IsDir":true}
        ]}
        """
        let list = try JSONDecoder().decode(ListResponse.self, from: Data(json.utf8)).list
        let items = list.map { $0.item(in: "/dir") }
        #expect(items[0].path == "/dir/a.txt")
        #expect(items[0].size == 12)
        #expect(items[0].isDirectory == false)
        #expect(items[1].isDirectory && items[1].size == nil)
        let expected = Date(timeIntervalSince1970: 1_714_979_289.123)
        #expect(abs(items[0].modified!.timeIntervalSince(expected)) < 0.01)
        #expect(items[1].modified == Date(timeIntervalSince1970: 1_714_979_289))
    }

    @Test func statWithNullItem() throws {
        let stat = try JSONDecoder().decode(StatResponse.self, from: Data(#"{"item":null}"#.utf8))
        #expect(stat.item == nil)
    }

    @Test func jobAndStats() throws {
        let status = try JSONDecoder().decode(
            JobStatus.self, from: Data(#"{"finished":true,"success":false,"error":"boom","duration":1.5,"id":3}"#.utf8)
        )
        #expect(status.finished && !status.success && status.error == "boom")
        let stats = try JSONDecoder().decode(
            Stats.self,
            from: Data(#"{"bytes":100,"lowLevelRetries":2,"transferring":[{"name":"f","bytes":40,"size":200}]}"#.utf8)
        )
        #expect(stats.bytes == 100 && stats.lowLevelRetries == 2 && stats.transferring?.first?.bytes == 40)
    }

    @Test func dates() {
        #expect(RcloneDate.parse("2024-05-06T07:08:09Z") != nil)
        #expect(RcloneDate.parse("2024-05-06T07:08:09.5+02:00") != nil)
        #expect(RcloneDate.parse("garbage") == nil)
    }
}

@Suite struct FileSystemMappingTests {
    @Test func connectListsRootAndLogsWithoutSecrets() async throws {
        let transport = FakeTransport { method, _ in
            method == "operations/list"
                ? ok(#"{"list":[{"Name":"b1","Size":-1,"ModTime":"2024-01-01T00:00:00Z","IsDir":true}]}"#)
                : ok("{}")
        }
        let config = ConnectionConfig(protocol: .rclone, host: "", username: "AK")
        let secrets = InMemorySecretStore()
        await secrets.setSecret("TOPSECRET", for: config.id, purpose: .cloudToken)
        let fs = RcloneFileSystem(config: config, spec: s3Spec(), secrets: secrets, transport: transport)
        let logs = LockedBox<[String]>([])
        let stream = fs.logStream
        let collector = Task { for await line in stream { logs.withLock { $0.append(line.message) } } }

        try await fs.connect()
        let items = try await fs.list("/")
        #expect(items.map(\.path) == ["/b1"])
        await fs.disconnect()
        try await Task.sleep(for: .milliseconds(100))
        collector.cancel()

        let all = logs.withLock { $0 }
        #expect(all.contains { $0.hasPrefix("rc operations/list") })
        #expect(all.allSatisfy { !$0.contains("TOPSECRET") })
    }

    @Test func operationsRequireConnect() async {
        let fs = RcloneFileSystem(
            config: ConnectionConfig(protocol: .rclone, host: "", username: ""), spec: s3Spec(),
            secrets: InMemorySecretStore(), transport: FakeTransport()
        )
        await #expect(throws: RemoteError.notConnected) { try await fs.list("/") }
    }

    @Test func connectErrorsAreMapped() async {
        let transport = FakeTransport { _, _ in
            RcloneResponse(status: 500, output: #"{"error":"InvalidAccessKeyId: The access key does not exist"}"#)
        }
        let config = ConnectionConfig(protocol: .rclone, host: "", username: "AK")
        let secrets = InMemorySecretStore()
        await secrets.setSecret("SK", for: config.id, purpose: .cloudToken)
        let fs = RcloneFileSystem(config: config, spec: s3Spec(), secrets: secrets, transport: transport)
        do {
            try await fs.connect()
            Issue.record("expected failure")
        } catch let error as RemoteError {
            guard case .authenticationFailed = error else { Issue.record("got \(error)"); return }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func deleteChoosesCallByKind() async throws {
        let transport = FakeTransport { method, params in
            guard method == "operations/stat" else { return ok("{}") }
            let isDir = params["remote"] == "dir"
            return ok(#"{"item":{"Name":"x","Size":\#(isDir ? -1 : 3),"ModTime":"2024-01-01T00:00:00Z","IsDir":\#(isDir)}}"#)
        }
        let fs = try await connectedFS(transport: transport)
        try await fs.delete("/file", recursive: false)
        try await fs.delete("/dir", recursive: true)
        try await fs.delete("/dir", recursive: false)
        let methods = transport.calls.map(\.method).filter { !["operations/list", "operations/stat"].contains($0) }
        #expect(methods == ["operations/deletefile", "operations/purge", "operations/rmdir"])
    }

    @Test func renameDirectoryUsesSyncMove() async throws {
        let transport = FakeTransport { method, _ in
            method == "operations/stat" ? ok(#"{"item":{"Name":"d","Size":-1,"IsDir":true}}"#) : ok("{}")
        }
        let fs = try await connectedFS(spec: s3Spec(root: "bucket"), transport: transport)
        try await fs.rename("/d", "/e")
        let call = try #require(transport.calls.last)
        #expect(call.method == "sync/move")
        guard case .string(let src)? = call.params["srcFs"], case .string(let dst)? = call.params["dstFs"] else {
            Issue.record("missing fs"); return
        }
        #expect(src.hasSuffix(":bucket/d") && dst.hasSuffix(":bucket/e"))
    }

    @Test func missingItemIsNotFound() async throws {
        let transport = FakeTransport { method, _ in
            method == "operations/stat" ? ok(#"{"item":null}"#) : ok("{}")
        }
        let fs = try await connectedFS(transport: transport)
        await #expect(throws: RemoteError.notFound("/nope")) { try await fs.delete("/nope", recursive: true) }
    }

    @Test func rootRule() async throws {
        let all = try await connectedFS(transport: FakeTransport())
        #expect(all.isRoot("/") && all.isRoot("/bucket") && all.isRoot("/bucket/"))
        #expect(!all.isRoot("/bucket/dir"))
        let rooted = try await connectedFS(spec: s3Spec(root: "bucket"), transport: FakeTransport())
        #expect(rooted.isRoot("/") && !rooted.isRoot("/dir"))
        #expect(all.supportsShell == false)
    }

    @Test func oauthDrivesStateMachine() async throws {
        let token = #"{"access_token":"A","refresh_token":"R"}"#
        let step = LockedBox(0)
        let transport = FakeTransport { method, _ in
            switch method {
            case "config/create":
                let n = step.withLock { n -> Int in n += 1; return n }
                return n == 1
                    ? ok(#"{"State":"s1","Option":{"Name":"config_is_local","Default":true},"Error":""}"#)
                    : ok(#"{"State":"","Error":""}"#)
            case "config/get":
                return ok(#"{"type":"drive","token":"{\"access_token\":\"A\",\"refresh_token\":\"R\"}"}"#)
            default:
                return ok("{}")
            }
        }
        let result = try await RcloneOAuth(client: RcloneClient(transport: transport)).authorize(backend: .drive)
        #expect(result == token)
        let creates = transport.calls.filter { $0.method == "config/create" }
        #expect(creates.count == 2)
        #expect(creates[1].params["opt"] != nil)
        await #expect(throws: RemoteError.self) {
            try await RcloneOAuth(client: RcloneClient(transport: transport)).authorize(backend: .s3)
        }
    }
}
