import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The WHM API 1 `create_user_session` services Dockyard opens.
public enum WHMService: String, Sendable, Equatable {
    case cpanel = "cpaneld"
    case whm = "whostmgrd"
}

/// A one-time login URL from WHM. Open it in the default browser right away: it expires after about a minute.
public struct WHMLoginSession: Sendable, Equatable {
    public var url: URL
    public var service: WHMService
    public var expires: Date?
    /// The session token that also appears in the URL path, e.g. `/cpsess1234567890`.
    public var securityToken: String?
}

extension WHMClient {
    func createUserSessionRequest(user: String, service: WHMService, app: String? = nil) throws -> URLRequest {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.port = port
        comps.path = "/json-api/create_user_session"
        var items = [URLQueryItem(name: "api.version", value: "1"), URLQueryItem(name: "user", value: user),
                     URLQueryItem(name: "service", value: service.rawValue)]
        if let app { items.append(URLQueryItem(name: "app", value: app)) }
        comps.queryItems = items
        guard !host.isEmpty, !host.contains("/"), !user.isEmpty, let url = comps.url else { throw WHMError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("whm \(apiUser):\(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    /// Asks WHM for a login URL for `user` on `service`. For the WHM service `user` must be the API user.
    public func createUserSession(user: String, service: WHMService, app: String? = nil) async throws -> WHMLoginSession {
        try Self.parseUserSession(try await perform(try createUserSessionRequest(user: user, service: service, app: app)), service: service)
    }

    /// One-click cPanel login for a hosting account.
    public func cpanelLogin(for account: String, app: String? = nil) async throws -> WHMLoginSession {
        try await createUserSession(user: account, service: .cpanel, app: app)
    }

    /// One-click WHM login as the API user.
    public func whmLogin() async throws -> WHMLoginSession {
        try await createUserSession(user: apiUser, service: .whm)
    }

    public static func parseUserSession(_ data: Data, service: WHMService) throws -> WHMLoginSession {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WHMError.invalidResponse("not a JSON object")
        }
        if let meta = root["metadata"] as? [String: Any], let result = int(meta["result"]), result == 0 {
            throw WHMError.api((meta["reason"] as? String) ?? "unknown error")
        }
        guard let payload = root["data"] as? [String: Any] else { throw WHMError.invalidResponse("missing data") }
        guard let text = nonEmpty(payload["url"]), let url = URL(string: text), url.scheme == "https", url.host != nil else {
            throw WHMError.invalidResponse("missing or insecure login URL")
        }
        return WHMLoginSession(
            url: url, service: service,
            expires: int(payload["expires"]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            securityToken: nonEmpty(payload["cp_security_token"]))
    }
}
