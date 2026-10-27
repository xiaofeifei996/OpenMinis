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
        let refreshExpiresIn: Int?
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
                    path: "/v2/plugin/auth/token?state=\(login.state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? login.state)",
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
                    expiresIn: payload["expiresIn"] as? Int,
                    refreshExpiresIn: payload["refreshExpiresIn"] as? Int,
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
                    "Authorization": "Bearer \\(accessToken)",
                    "X-No-User-Id": "true",
                    "X-No-Enterprise-Id": "true"
                ]
                headers["X-Domain"] = domain ?? endpoint.host
                let payload = try await requestJSON(
                    path: "/v2/plugin/login/account?state=\\(login.state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? login.state)",
                    method: "GET",
                    headers: headers,
                    body: nil,
                    session: session
                )
                guard let uid = payload["uid"] as? String, !uid.isEmpty else {
                    throw FlowError.invalidResponse
                }
                return Account(
                    userID: uid,
                    nickname: payload["nickname"] as? String,
                    phoneNumber: payload["phoneNumber"] as? String,
                    domain: payload["domain"] as? String ?? domain,
                    enterpriseID: payload["enterpriseId"] as? String
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

    @MainActor
    static func openAuthorizationPage(_ login: LoginState) {
        UIApplication.shared.open(login.authorizationURL)
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
        let code = json["code"] as? Int ?? 0
        guard code == 0 else {
            throw FlowError.server(code: code, message: (json["msg"] as? String) ?? "WorkBuddy request failed.")
        }
        if let data = json["data"] as? [String: Any] { return data }
        return json
    }
}
