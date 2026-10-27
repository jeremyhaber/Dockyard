import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One cPanel account from WHM API 1 `listaccts`.
public struct WHMAccount: Sendable, Equatable {
    public var user: String
    public var domain: String
    public var email: String?
    public var plan: String?
    public var ip: String?
    public var owner: String?
    public var suspended: Bool
    public var suspendReason: String?
    public var diskUsed: String?
    public var startDate: Date?

    public init(user: String, domain: String, email: String? = nil, plan: String? = nil, ip: String? = nil, owner: String? = nil,
                suspended: Bool = false, suspendReason: String? = nil, diskUsed: String? = nil, startDate: Date? = nil) {
        self.user = user; self.domain = domain; self.email = email; self.plan = plan; self.ip = ip; self.owner = owner
        self.suspended = suspended; self.suspendReason = suspendReason; self.diskUsed = diskUsed; self.startDate = startDate
    }
}

public enum WHMError: Error, Equatable, CustomStringConvertible {
    case invalidURL
    case unauthorized
    case http(Int)
    case api(String)
    case invalidResponse(String)
    case transport(String)

    public var description: String {
        switch self {
        case .invalidURL: "Invalid WHM host"
        case .unauthorized: "WHM rejected the API token (check the token and that it has the list-accts privilege)"
        case .http(let code): "WHM returned HTTP \(code)"
        case .api(let reason): "WHM API error: \(reason)"
        case .invalidResponse(let m): "Unexpected WHM response: \(m)"
        case .transport(let m): "Could not reach WHM: \(m)"
        }
    }
}

/// Seam for tests. The production implementation uses URLSession.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// WHM servers often present self-signed certificates on port 2087; `trustSelfSigned` accepts those for the WHM host only.
    public init(timeout: TimeInterval = 30, trustSelfSignedFor host: String? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 4
        if let host {
            session = URLSession(configuration: config, delegate: SelfSignedTrustDelegate(host: host), delegateQueue: nil)
        } else {
            session = URLSession(configuration: config)
        }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WHMError.invalidResponse("not an HTTP response") }
        return (data, http)
    }
}

private final class SelfSignedTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let host: String
    init(host: String) { self.host = host }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        #if canImport(Security)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == host, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }
}

public struct WHMClient: Sendable {
    public let host: String
    public let port: Int
    public let apiUser: String
    private let token: String
    private let transport: any HTTPTransport

    public init(host: String, port: Int = 2087, apiUser: String = "root", token: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.host = host; self.port = port; self.apiUser = apiUser; self.token = token; self.transport = transport
    }

    /// Builds the request. The token only ever appears in the `Authorization` header.
    func listAccountsRequest() throws -> URLRequest {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.port = port
        comps.path = "/json-api/listaccts"
        comps.queryItems = [URLQueryItem(name: "api.version", value: "1")]
        guard !host.isEmpty, !host.contains("/"), let url = comps.url else { throw WHMError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("whm \(apiUser):\(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    public func listAccounts() async throws -> [WHMAccount] {
        let request = try listAccountsRequest()
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) } catch let e as WHMError { throw e } catch {
            throw WHMError.transport(Self.scrub(error.localizedDescription, token: token))
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw WHMError.unauthorized
        default: throw WHMError.http(response.statusCode)
        }
        return try Self.parse(data)
    }

    static func scrub(_ message: String, token: String) -> String {
        token.count >= 3 ? message.replacingOccurrences(of: token, with: "****") : message
    }

    /// Parses a `listaccts` JSON body.
    public static func parse(_ data: Data) throws -> [WHMAccount] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WHMError.invalidResponse("not a JSON object")
        }
        if let meta = root["metadata"] as? [String: Any], let result = Self.int(meta["result"]), result == 0 {
            throw WHMError.api((meta["reason"] as? String) ?? "unknown error")
        }
        guard let payload = root["data"] as? [String: Any] else { throw WHMError.invalidResponse("missing data") }
        // An empty server returns no `acct` key or null.
        guard let list = payload["acct"] as? [[String: Any]] else { return [] }
        return list.compactMap { a in
            guard let user = (a["user"] as? String)?.trimmingCharacters(in: .whitespaces), !user.isEmpty else { return nil }
            let suspended = Self.int(a["suspended"]).map { $0 != 0 } ?? (a["suspended"] as? Bool ?? false)
            return WHMAccount(
                user: user,
                domain: (a["domain"] as? String) ?? "",
                email: Self.nonEmpty(a["email"]),
                plan: Self.nonEmpty(a["plan"]),
                ip: Self.nonEmpty(a["ip"]),
                owner: Self.nonEmpty(a["owner"]),
                suspended: suspended,
                suspendReason: suspended ? Self.nonEmpty(a["suspendreason"]) : nil,
                diskUsed: Self.nonEmpty(a["diskused"]),
                startDate: Self.int(a["unix_startdate"]).map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
    }

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    private static func nonEmpty(_ v: Any?) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s != "*unknown*" else { return nil }
        return s
    }
}
