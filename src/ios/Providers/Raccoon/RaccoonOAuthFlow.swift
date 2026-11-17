import Foundation
import AuthenticationServices
import UIKit

/// SenseTime Raccoon (商汤「小浣熊」) sign-in and model catalog.
///
/// This is the NATIVE client half of the desktop client's login protocol. The
/// flow is deliberately not a standard OAuth server: the browser hands back a
/// one-time authorization CODE through the `office-raccoon://auth/callback`
/// custom scheme, and that code is exchanged for tokens server-side at
/// `POST {authBase}/login_with_authorization_code`. There is no PKCE and no
/// client id — the desktop app's `login_source=desktop` marker is the whole
/// client identity, which is why this integration is opt-in and unattributed
/// to the vendor.
///
/// Credentials are persisted by the caller in the Keychain; nothing here logs
/// token material, and the raw authorization code never leaves this type.
enum RaccoonOAuthFlow {
    /// Site origin. Authorization pages live here, not under the API bases.
    static let origin = "https://xiaohuanxiong.com"
    /// LLM gateway: `/chat/completions` and `/model_catalog` hang off this.
    static let llmBase = "https://xiaohuanxiong.com/api/web/llm/v2"
    /// Auth domain: code exchange and token refresh.
    static let authBase = "https://xiaohuanxiong.com/api/web/auth/v1"
    /// Desktop-client callback scheme. Declared by the official client; on iOS
    /// nothing else claims it, so ASWebAuthenticationSession intercepts it.
    static let callbackScheme = "office-raccoon"
    /// The `appname` the authorization page displays.
    static let appName = "办公小浣熊客户端"
    static let userAgent = "MinisRaccoon/1.0"
    static let signInTimeout: TimeInterval = 5 * 60

    /// Upstream business code for "authorization code expired or already used".
    /// Worth its own case because retrying is pointless — the user has to start
    /// over, and the message has to say so.
    static let codeAuthorizationCodeExpired = 200035

    struct Credentials: Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Double?
        let userID: String?
    }

    enum FlowError: LocalizedError {
        case invalidResponse
        case cancelled
        case timedOut
        case stateMismatch
        case server(code: Int, message: String)
        case authorizationCodeExpired
        case missingCredentials
        case emptyModelCatalog

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "小浣熊返回了无法识别的响应。"
            case .cancelled:
                return "已取消登录。"
            case .timedOut:
                return "登录超时，请重试。"
            case .stateMismatch:
                return "登录回调校验失败，请重新登录。"
            case .server(_, let message):
                return message
            case .authorizationCodeExpired:
                return "授权码已失效，请重新发起登录。"
            case .missingCredentials:
                return "小浣熊登录未返回访问令牌。"
            case .emptyModelCatalog:
                return "登录成功，但小浣熊没有返回任何可用模型。请确认账号有模型权限。"
            }
        }
    }

    // MARK: - Login

    struct LoginState: Sendable {
        let state: String
        let authorizationURL: URL
    }

    /// Build the authorization URL. `state` is generated here (32 hex chars)
    /// and verified against the callback — without that check the app would
    /// exchange a code handed to it by whoever opened the callback URL.
    static func begin() throws -> LoginState {
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard var components = URLComponents(string: origin + "/code/authorize") else {
            throw FlowError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "login_source", value: "desktop"),
            URLQueryItem(name: "appname", value: appName),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { throw FlowError.invalidResponse }
        return LoginState(state: state, authorizationURL: url)
    }

    /// Run the browser leg and return the callback URL. Presented in-app by
    /// ASWebAuthenticationSession so the custom-scheme redirect comes straight
    /// back here instead of leaving the user in Safari with a URL to copy.
    @MainActor
    static func authorize(_ login: LoginState) async throws -> URL {
        let presenter = RaccoonAuthPresenter()
        defer { presenter.finish() }
        return try await presenter.run(url: login.authorizationURL, scheme: callbackScheme)
    }

    /// Pull `code` out of the callback URL, rejecting anything that is not the
    /// desktop client's exact callback shape and state.
    static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard callbackURL.scheme?.lowercased() == callbackScheme,
              callbackURL.host?.lowercased() == "auth",
              callbackURL.path == "/callback" else {
            throw FlowError.invalidResponse
        }
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let state = value("state"), !state.isEmpty, state == expectedState else {
            throw FlowError.stateMismatch
        }
        guard let code = value("code"), !code.isEmpty, code.count <= 8192 else {
            throw FlowError.invalidResponse
        }
        return code
    }

    /// Exchange the one-time code for tokens.
    static func exchange(code: String, session: URLSession = .shared) async throws -> Credentials {
        let payload = try await requestJSON(
            url: authBase + "/login_with_authorization_code",
            method: "POST",
            body: ["authorization_code": code],
            bearer: nil,
            session: session
        )
        guard let access = payload["access_token"] as? String, !access.isEmpty,
              let refresh = payload["refresh_token"] as? String, !refresh.isEmpty else {
            throw FlowError.missingCredentials
        }
        return Credentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: RaccoonJWT.expiry(access),
            userID: RaccoonJWT.userID(access)
        )
    }

    /// Full sign-in: browser → code → tokens.
    @MainActor
    static func signIn(session: URLSession = .shared) async throws -> Credentials {
        let login = try begin()
        let callback = try await authorize(login)
        let code = try authorizationCode(from: callback, expectedState: login.state)
        return try await exchange(code: code, session: session)
    }

    // MARK: - Refresh

    /// Refresh tokens. `refreshToken` may be rotated upstream — callers must
    /// persist the returned value when it differs.
    static func refresh(
        refreshToken: String,
        session: URLSession = .shared
    ) async throws -> (accessToken: String, refreshToken: String?) {
        let payload = try await requestJSON(
            url: authBase + "/refresh",
            method: "POST",
            body: ["refresh_token": refreshToken],
            bearer: nil,
            session: session
        )
        guard let access = payload["access_token"] as? String, !access.isEmpty else {
            throw FlowError.missingCredentials
        }
        let rotated = payload["refresh_token"] as? String
        return (access, (rotated?.isEmpty == false) ? rotated : nil)
    }

    // MARK: - Model catalog

    /// Fetch the account-scoped model catalog.
    ///
    /// The catalog is the vendor's own list, so nothing is hardcoded: a model
    /// added or withdrawn upstream shows up immediately. Entries flagged
    /// `visible: false` are internal (undocumented `raccoon-*` ids) and are
    /// dropped, matching what the vendor's picker shows.
    static func fetchModels(accessToken: String, session: URLSession = .shared) async throws -> [LLMModel] {
        let payload = try await requestJSON(
            url: llmBase + "/model_catalog",
            method: "GET",
            body: nil,
            bearer: accessToken,
            session: session
        )
        let categories = payload["categories"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        var models: [LLMModel] = []
        for category in categories {
            for entry in category["models"] as? [[String: Any]] ?? [] {
                guard let model = model(from: entry), seen.insert(model.id).inserted else { continue }
                models.append(model)
            }
        }
        guard !models.isEmpty else { throw FlowError.emptyModelCatalog }
        return models
    }

    private static func model(from entry: [String: Any]) -> LLMModel? {
        let id = (entry["name"] as? String ?? entry["model_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id, !id.isEmpty, id.count <= 256 else { return nil }
        // Internal models are hidden from the vendor's own picker — offering
        // them here would just produce upstream errors.
        if let visible = entry["visible"] as? Bool, !visible { return nil }

        let displayDescription = (entry["display_description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let codeName = (entry["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = [displayDescription, codeName]
            .compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }
            .first ?? id

        let params = entry["params"] as? [String: Any]
        let context = intValue(entry["context_window"]) ?? intValue(params?["context_window"])
        let maxOut = intValue(entry["max_tokens"]) ?? intValue(params?["max_tokens"])
        // The catalog publishes no capability flags, so neither `supportsReasoning`
        // nor `interleavedReasoningField` is inferred from a model name: the
        // first keeps the thinking engine's permissive default, and leaving the
        // second nil avoids echoing a `reasoning_content` the gateway may not
        // accept back in history. Thinking deltas are still surfaced, because
        // the agent provider reads that field unconditionally.
        return LLMModel(
            id: id,
            displayName: displayName,
            provider: "小浣熊",
            contextWindow: context,
            maxOutputTokens: maxOut
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        let number: Double?
        if let n = value as? NSNumber { number = n.doubleValue }
        else if let s = value as? String { number = Double(s) }
        else { number = nil }
        guard let number, number > 0 else { return nil }
        return Int(number)
    }

    // MARK: - Transport

    /// One JSON request with the upstream's envelope unwrapped.
    ///
    /// The vendor answers `{ "code": 0, "data": { … } }` on success and a
    /// non-zero `code` plus `message` on failure — the HTTP status alone is not
    /// authoritative (a bad authorization code comes back as HTTP 400 with
    /// code 200035).
    private static func requestJSON(
        url: String,
        method: String,
        body: [String: Any]?,
        bearer: String?,
        session: URLSession
    ) async throws -> [String: Any] {
        guard let requestURL = URL(string: url) else { throw FlowError.invalidResponse }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FlowError.invalidResponse
        }
        let code: Int
        if let n = json["code"] as? NSNumber { code = n.intValue }
        else if let s = json["code"] as? String, let parsed = Int(s) { code = parsed }
        else { code = 0 }

        if code == codeAuthorizationCodeExpired { throw FlowError.authorizationCodeExpired }
        if code != 0 {
            let message = (json["message"] as? String)
                ?? (json["msg"] as? String)
                ?? (json["details"] as? String)
                ?? "小浣熊请求失败（code \(code)）"
            throw FlowError.server(code: code, message: message)
        }
        guard (200...299).contains(status) else {
            let message = (json["message"] as? String) ?? "小浣熊返回 HTTP \(status)"
            throw FlowError.server(code: status, message: message)
        }
        if let inner = json["data"] as? [String: Any] { return inner }
        return json
    }
}

// MARK: - JWT (payload only, never verified)

/// Reads claims out of the access token for display and expiry only. The
/// signature is NOT checked — the token's authority comes from the server that
/// issued it, and we never make a trust decision with these values.
enum RaccoonJWT {
    static func payload(_ token: String) -> [String: Any]? {
        let trimmed = token.hasPrefix("Bearer ") ? String(token.dropFirst(7)) : token
        let parts = trimmed.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// Expiry as an absolute epoch second, or nil when the claim is absent.
    static func expiry(_ token: String) -> Double? {
        guard let raw = payload(token)?["exp"] else { return nil }
        let seconds: Double?
        if let n = raw as? NSNumber { seconds = n.doubleValue }
        else if let s = raw as? String { seconds = Double(s) }
        else { seconds = nil }
        guard let seconds, seconds > 0 else { return nil }
        return seconds
    }

    static func userID(_ token: String) -> String? {
        guard let claims = payload(token) else { return nil }
        for key in ["user_id", "userId", "uid", "userID"] {
            if let s = claims[key] as? String, !s.isEmpty { return s }
            if let n = claims[key] as? NSNumber, n.intValue != 0 { return n.stringValue }
        }
        return nil
    }
}

// MARK: - ASWebAuthenticationSession host

/// Retains the session for its lifetime and supplies the presentation anchor.
///
/// `ASWebAuthenticationSession` intercepts the callback scheme itself, so no
/// Info.plist URL type is needed — the app never claims `office-raccoon`.
@MainActor
private final class RaccoonAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    func run(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            continuation = cont
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: scheme
            ) { [weak self] callbackURL, error in
                // The completion handler is @Sendable and may fire off the main
                // actor; hop back before touching state.
                Task { @MainActor in self?.resume(callbackURL: callbackURL, error: error) }
            }
            session.presentationContextProvider = self
            // Keep any existing browser session: the user is very likely already
            // signed in to xiaohuanxiong.com, and forcing a fresh one would both
            // annoy them and lose SMS verification state.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                resume(callbackURL: nil, error: RaccoonOAuthFlow.FlowError.invalidResponse)
            }
        }
    }

    private func resume(callbackURL: URL?, error: Error?) {
        guard let cont = continuation else { return }
        continuation = nil
        if let callbackURL {
            cont.resume(returning: callbackURL)
        } else if let error, (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
            cont.resume(throwing: RaccoonOAuthFlow.FlowError.cancelled)
        } else {
            cont.resume(throwing: error ?? RaccoonOAuthFlow.FlowError.invalidResponse)
        }
    }

    func finish() {
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}
