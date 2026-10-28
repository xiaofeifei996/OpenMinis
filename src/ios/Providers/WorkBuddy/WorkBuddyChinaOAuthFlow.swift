import Foundation
import UIKit

/// WorkBuddy China browser-login flow.
///
/// This is the native client-side half of WorkBuddy's plugin login protocol.
/// Tokens and account metadata must be persisted by the caller in Keychain;
/// this type deliberately does not store credentials or log secrets.
enum WorkBuddyChinaOAuthFlow {
    static let endpoint = URL(string: "https://copilot.tencent.com")!
    static let userAgent = "WorkBuddy/5.5.6"
    static let signInTimeout: TimeInterval = 5 * 60

    struct LoginState: Sendable {
        let state: String
        let authorizationURL: URL
    }

    struct Token: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?
        let expiresAt: Double?
        let refreshExpiresIn: Int?
        let refreshExpiresAt: Double?
        let domain: String?
        let tokenType: String?
    }

    enum FlowError: LocalizedError {
        case invalidResponse
        case server(code: Int, message: String)
        case timeout
        case missingToken

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "WorkBuddy returned an invalid response."
            case .server(_, let message): return message
            case .timeout: return "WorkBuddy sign-in timed out. Please try again."
            case .missingToken: return "WorkBuddy sign-in completed without an access token."
            }
        }
    }

    /// Request a short-lived state and browser authorization URL.
    static func begin(session: URLSession = .shared) async throws -> LoginState {
        let payload = try await requestJSON(
            path: "/v2/plugin/auth/state?platform=workbuddy",
            method: "POST",
            headers: [
                "X-No-Authorization": "true",
                "X-No-User-Id": "true",
                "X-No-Enterprise-Id": "true",
                "X-No-Department-Info": "true"
            ],
            body: Data("{}".utf8),
            session: session
        )
        guard let state = payload["state"] as? String,
              let rawURL = payload["authUrl"] as? String,
              var components = URLComponents(string: rawURL) else {
            throw FlowError.invalidResponse
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "version", value: "2.0.0"))
        items.append(URLQueryItem(name: "loginSessionId", value: UUID().uuidString))
        components.queryItems = items
        guard let url = components.url else { throw FlowError.invalidResponse }
        return LoginState(state: state, authorizationURL: url)
    }

    /// Poll the token endpoint while the user authorizes in the browser.
    /// WorkBuddy business code 11217 means authorization is still pending.
    static func pollToken(
        for login: LoginState,
        timeout: TimeInterval = signInTimeout,
        session: URLSession = .shared,
        onPending: (() -> Void)? = nil
    ) async throws -> Token {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try Task.checkCancellation()
            do {
                let payload = try await requestJSON(
                    path: "/v2/plugin/auth/token?state=\(Self.encodeQueryValue(login.state))",
                    method: "GET",
                    headers: [
                        "X-No-Authorization": "true",
                        "X-No-User-Id": "true",
                        "X-No-Enterprise-Id": "true",
                        "X-No-Department-Info": "true"
                    ],
                    body: nil,
                    session: session
                )
                guard let access = payload["accessToken"] as? String, !access.isEmpty else {
                    throw FlowError.missingToken
                }
                return Token(
                    accessToken: access,
                    refreshToken: payload["refreshToken"] as? String,
                    expiresIn: Self.seconds(payload["expiresIn"]),
                    expiresAt: Self.timestamp(payload["expiresAt"]),
                    refreshExpiresIn: Self.seconds(payload["refreshExpiresIn"]),
                    refreshExpiresAt: Self.timestamp(payload["refreshExpiresAt"]),
                    domain: payload["domain"] as? String,
                    tokenType: payload["tokenType"] as? String
                )
            } catch let error as FlowError {
                if case .server(let code, _) = error, code == 11217 {
                    onPending?()
                    continue
                }
                throw error
            }
        }
        throw FlowError.timeout
    }

    /// Open the authorization URL using the system browser.
    struct Account: Sendable {
        let userID: String
        let nickname: String?
        let phoneNumber: String?
        let domain: String?
        let enterpriseID: String?
        let accountType: String?
    }

    /// Waits for the browser login to be approved and retrieves the account
    /// identity needed by WorkBuddy's request headers.
    static func pollAccount(
        for login: LoginState,
        accessToken: String,
        domain: String?,
        timeout: TimeInterval = signInTimeout,
        session: URLSession = .shared,
        onPending: (() -> Void)? = nil
    ) async throws -> Account {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try Task.checkCancellation()
            do {
                var headers = [
                    "Authorization": "Bearer \(accessToken)",
                    "X-No-User-Id": "true",
                    "X-No-Enterprise-Id": "true"
                ]
                headers["X-Domain"] = domain ?? endpoint.host
                let payload = try await requestJSON(
                    path: "/v2/plugin/login/account?state=\(Self.encodeQueryValue(login.state))",
                    method: "GET",
                    headers: headers,
                    body: nil,
                    session: session
                )
                guard let uid = payload["uid"] as? String, !uid.isEmpty else {
                    throw FlowError.invalidResponse
                }
                let accountType = (payload["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                var enterpriseID = (payload["enterpriseId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if (enterpriseID ?? "").isEmpty, let accountType, !accountType.isEmpty, accountType.lowercased() != "personal" {
                    // Some enterprise accounts omit enterpriseId from /login/account.
                    if let listed = try? await requestJSON(path: "/v2/plugin/accounts", method: "GET", headers: headers, body: nil, session: session) {
                        let accounts = listed["accounts"] as? [[String: Any]] ?? []
                        let matching = accounts.filter {
                            ($0["uid"] as? String) == uid && !(($0["enterpriseId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
                        }
                        let sameType = matching.filter { (($0["type"] as? String)?.lowercased() ?? "") == accountType.lowercased() }
                        let lastUsed = matching.filter { entry in
                            let value = entry["lastLogin"]
                            if value == nil || value is NSNull { return false }
                            if let text = value as? String { return !text.isEmpty }
                            if let number = value as? NSNumber { return number.doubleValue != 0 }
                            return true
                        }
                        var selected: [String: Any]?
                        if sameType.count == 1 { selected = sameType[0] }
                        else if lastUsed.count == 1 { selected = lastUsed[0] }
                        else if matching.count == 1 { selected = matching[0] }
                        enterpriseID = selected?["enterpriseId"] as? String
                    }
                }
                return Account(
                    userID: uid,
                    nickname: payload["nickname"] as? String,
                    phoneNumber: payload["phoneNumber"] as? String,
                    domain: payload["domain"] as? String ?? domain,
                    enterpriseID: (enterpriseID ?? "").isEmpty ? nil : enterpriseID,
                    accountType: accountType
                )
            } catch let error as FlowError {
                if case .server(let code, _) = error, code == 12151 {
                    onPending?()
                    continue
                }
                throw error
            }
        }
        throw FlowError.timeout
    }

    /// Exchanges a saved refresh token for a new access token.
    /// Callers should replace the Keychain values only after this succeeds.
    static func refreshToken(
        _ refreshToken: String,
        domain: String?,
        enterpriseID: String? = nil,
        session: URLSession = .shared
    ) async throws -> Token {
        var headers = [
            "X-Refresh-Token": refreshToken,
            "X-Auth-Refresh-Source": "plugin"
        ]
        headers["X-Domain"] = domain ?? endpoint.host
        if let enterpriseID, !enterpriseID.isEmpty {
            headers["X-Enterprise-Id"] = enterpriseID
            headers["X-Tenant-Id"] = enterpriseID
        }
        let payload = try await requestJSON(
            path: "/v2/plugin/auth/token/refresh",
            method: "POST",
            headers: headers,
            body: Data("{}".utf8),
            session: session
        )
        guard let access = payload["accessToken"] as? String, !access.isEmpty else {
            throw FlowError.missingToken
        }
        return Token(
            accessToken: access,
            refreshToken: payload["refreshToken"] as? String,
            expiresIn: Self.seconds(payload["expiresIn"]),
            expiresAt: Self.timestamp(payload["expiresAt"]),
            refreshExpiresIn: Self.seconds(payload["refreshExpiresIn"]),
            refreshExpiresAt: Self.timestamp(payload["refreshExpiresAt"]),
            domain: payload["domain"] as? String ?? domain,
            tokenType: payload["tokenType"] as? String
        )
    }

    /// Fetch the account-scoped model catalog used by WorkBuddy's model picker.
    /// The generic OpenAI-compatible /v2/models endpoint may only expose `auto`.
    static func fetchModels(accessToken: String, session: URLSession = .shared) async throws -> [LLMModel] {
        let payload = try await requestJSON(
            path: "/v3/config?repos=",
            method: "GET",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "X-Domain": endpoint.host ?? "copilot.tencent.com",
                "X-No-Enterprise-Id": "true",
                "X-No-Department-Info": "true"
            ],
            body: nil,
            session: session
        )
        let agents = payload["agents"] as? [String: Any]
        let cli = agents?["cli"] as? [String: Any]
        let rawModels = (cli?["models"] as? [[String: Any]])
            ?? (payload["models"] as? [[String: Any]])
            ?? (agents?.values.compactMap { ($0 as? [String: Any])?["models"] as? [[String: Any]] }.first)
            ?? []
        var seen = Set<String>()
        return rawModels.compactMap { item in
            let rawID = (item["id"] ?? item["model"] ?? item["name"]) as? String
            guard let id = rawID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty, id.count <= 256, seen.insert(id).inserted else { return nil }
            let rawName = (item["displayName"] ?? item["name"] ?? item["title"]) as? String
            let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return LLMModel(
                id: id,
                displayName: (name?.isEmpty == false) ? (name ?? id) : id,
                provider: "WorkBuddy 中国版",
                modalityOverride: .textOnly,
                contextWindow: 168_000,
                supportsReasoning: false
            )
        }
    }

    @MainActor
    static func openAuthorizationPage(_ login: LoginState) {
        UIApplication.shared.open(login.authorizationURL)
    }

    /// WorkBuddy may return lifetimes in seconds or absolute expiry timestamps.
    /// Normalize absolute millisecond timestamps before persisting them.
    private static func seconds(_ value: Any?) -> Int? {
        guard let number = numericValue(value), number > 0 else { return nil }
        if number > 1_000_000_000_000 {
            return max(0, Int(number / 1000 - Date().timeIntervalSince1970))
        }
        return Int(number)
    }

    private static func timestamp(_ value: Any?) -> Double? {
        guard let number = numericValue(value), number > 0 else { return nil }
        return number > 1_000_000_000_000 ? number / 1000 : number
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// Percent-encode opaque query values without leaving reserved delimiters
    /// such as &, +, and = unescaped. urlQueryAllowed leaves some untouched.
    private static func encodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func requestJSON(
        path: String,
        method: String,
        headers: [String: String],
        body: Data?,
        session: URLSession
    ) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: endpoint) else {
            throw FlowError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FlowError.invalidResponse
        }
        let code: Int
        if let number = json["code"] as? NSNumber {
            code = number.intValue
        } else if let text = json["code"] as? String, let parsed = Int(text) {
            code = parsed
        } else {
            code = 0
        }
        guard code == 0 else {
            throw FlowError.server(code: code, message: (json["msg"] as? String) ?? "WorkBuddy request failed.")
        }
        if let data = json["data"] as? [String: Any] { return data }
        return json
    }
}
