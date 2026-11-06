import Foundation

/// Keeps Raccoon (小浣熊) credentials usable for outgoing requests.
///
/// Mirrors the other per-instance OAuth managers here: a 5-minute refresh
/// buffer, one in-flight refresh Task per instance (so concurrent turns cannot
/// rotate the same refresh token twice and lock the account out), and every
/// failure surfaced as "sign in again" instead of a raw HTTP 401 later.
@MainActor
final class RaccoonOAuthManager {
    static let shared = RaccoonOAuthManager()
    private init() {}

    private let logger = AppLogger(category: "RaccoonOAuth")
    /// Refresh this many seconds before expiry — same as Codex/Claude/Kimi.
    private let refreshBuffer: TimeInterval = 5 * 60

    // Keychain account names. The access token deliberately does NOT live in
    // `manual-oauth-token`: that slot means "a bearer the user pasted by hand"
    // everywhere else in the app (the factory prefers it over the managed
    // session, and the detail view labels it "manual token"). Raccoon has a
    // real sign-in, so it gets its own slot and the manual slot stays free for
    // a pasted token, which then wins over the session.
    enum Account {
        static let access = "raccoon-access-token"
        static let refresh = "raccoon-refresh-token"
        static let expiry = "raccoon-access-expiry"
        static let userID = "raccoon-user-id"
    }

    private var inFlightRefresh: [String: Task<String, Error>] = [:]

    enum ManagerError: LocalizedError {
        case notSignedIn
        case refreshExpired

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "小浣熊尚未登录，请重新登录。"
            case .refreshExpired:
                return "小浣熊登录已过期，请重新登录。"
            }
        }
    }

    // MARK: - Status

    func isAuthenticated(instanceId: String) -> Bool {
        ProviderKeychainHelper.loadOAuthString(instanceId: instanceId, account: Account.access)?
            .isEmpty == false
    }

    func maskedToken(instanceId: String) -> String? {
        guard let token = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: Account.access
        ), token.count > 8 else { return nil }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }

    func accountID(instanceId: String) -> String? {
        ProviderKeychainHelper.loadOAuthString(instanceId: instanceId, account: Account.userID)
    }

    /// Sign out: drop every credential this manager wrote.
    func logout(instanceId: String) {
        inFlightRefresh[instanceId]?.cancel()
        inFlightRefresh[instanceId] = nil
        for account in [Account.access, Account.refresh, Account.expiry, Account.userID] {
            ProviderKeychainHelper.deleteOAuthString(instanceId: instanceId, account: account)
        }
        logger.info("logout instanceId=\(instanceId.prefix(8))")
    }

    // MARK: - Sign-in

    /// Present the browser login and persist the result.
    @discardableResult
    func login(instanceId: String) async throws -> String {
        let credentials = try await RaccoonOAuthFlow.signIn()
        persist(credentials, instanceId: instanceId)
        logger.info("signed in instanceId=\(instanceId.prefix(8)) user=\(credentials.userID?.prefix(24) ?? "?")")
        return credentials.accessToken
    }

    private func persist(_ credentials: RaccoonOAuthFlow.Credentials, instanceId: String) {
        ProviderKeychainHelper.saveOAuthString(
            credentials.accessToken, instanceId: instanceId, account: Account.access)
        if !credentials.refreshToken.isEmpty {
            ProviderKeychainHelper.saveOAuthString(
                credentials.refreshToken, instanceId: instanceId, account: Account.refresh)
        }
        if let expiresAt = credentials.expiresAt {
            ProviderKeychainHelper.saveOAuthString(
                String(expiresAt), instanceId: instanceId, account: Account.expiry)
        } else {
            ProviderKeychainHelper.deleteOAuthString(instanceId: instanceId, account: Account.expiry)
        }
        if let userID = credentials.userID, !userID.isEmpty {
            ProviderKeychainHelper.saveOAuthString(
                userID, instanceId: instanceId, account: Account.userID)
        }
    }

    // MARK: - Token

    /// A usable access token, refreshing first when it is close to expiry.
    func validAccessToken(instanceId: String) async throws -> String {
        guard let access = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: Account.access
        ), !access.isEmpty else {
            throw ManagerError.notSignedIn
        }

        let expiry = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: Account.expiry
        ).flatMap(TimeInterval.init)
        if let expiry, expiry > Date().timeIntervalSince1970 + refreshBuffer {
            return access
        }

        // Actor isolation alone does not serialize across await points: two
        // turns can both read the (expired) token and both start a refresh.
        // The second POST would present an already-rotated refresh token and
        // log the account out, so callers share one Task.
        return try await sharedRefresh(instanceId: instanceId)
    }

    /// Force a refresh — used after an upstream 401 even when the stored expiry
    /// still looks valid (clock skew, or the server revoked the token early).
    func forceRefresh(instanceId: String) async throws -> String {
        try await sharedRefresh(instanceId: instanceId)
    }

    private func sharedRefresh(instanceId: String) async throws -> String {
        if let existing = inFlightRefresh[instanceId] {
            return try await existing.value
        }
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw ManagerError.notSignedIn }
            return try await self.performRefresh(instanceId: instanceId)
        }
        inFlightRefresh[instanceId] = task
        defer { inFlightRefresh[instanceId] = nil }
        return try await task.value
    }

    static func expireIfNeeded(_ error: Error) -> Bool {
        guard let flowError = error as? RaccoonOAuthFlow.FlowError else { return false }
        switch flowError {
        case .authorizationCodeExpired:
            return true
        case .server(let code, _):
            return code == 401 || code == 403 || code == 100002
        default:
            return false
        }
    }

    private func performRefresh(instanceId: String) async throws -> String {
        guard let refresh = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: Account.refresh
        ), !refresh.isEmpty else {
            throw ManagerError.notSignedIn
        }

        let result: (accessToken: String, refreshToken: String?)
        do {
            result = try await RaccoonOAuthFlow.refresh(refreshToken: refresh)
        } catch let error where Self.expireIfNeeded(error) {
            // The refresh token itself is dead: keeping it would make every
            // later request fail with the same upstream code.
            logout(instanceId: instanceId)
            throw ManagerError.refreshExpired
        }

        ProviderKeychainHelper.saveOAuthString(
            result.accessToken, instanceId: instanceId, account: Account.access)
        if let rotated = result.refreshToken, !rotated.isEmpty {
            ProviderKeychainHelper.saveOAuthString(
                rotated, instanceId: instanceId, account: Account.refresh)
        }
        if let expiry = RaccoonJWT.expiry(result.accessToken) {
            ProviderKeychainHelper.saveOAuthString(
                String(expiry), instanceId: instanceId, account: Account.expiry)
        } else {
            ProviderKeychainHelper.deleteOAuthString(instanceId: instanceId, account: Account.expiry)
        }
        logger.info("refreshed instanceId=\(instanceId.prefix(8)) rotated=\(result.refreshToken != nil)")
        return result.accessToken
    }
}
