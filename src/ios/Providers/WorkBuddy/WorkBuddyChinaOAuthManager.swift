import Foundation

/// Keeps WorkBuddy China OAuth credentials usable for outgoing model requests.
/// Refreshes only when the cached access token is near expiry.
@MainActor
final class WorkBuddyChinaOAuthManager {
    static let shared = WorkBuddyChinaOAuthManager()
    private init() {}

    enum ManagerError: LocalizedError {
        case notSignedIn
        case refreshExpired
        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in to WorkBuddy China again to continue."
            case .refreshExpired: return "Your WorkBuddy China session expired. Please sign in again."
            }
        }
    }

    func validAccessToken(instanceId: String) async throws -> String {
        guard let access = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: "manual-oauth-token"
        ), !access.isEmpty else {
            throw ManagerError.notSignedIn
        }

        let expiry = TimeInterval(ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: "workbuddy-access-expiry"
        ) ?? "")
        if let expiry, expiry > Date().timeIntervalSince1970 + 300 {
            return access
        }

        guard let refresh = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: "workbuddy-refresh-token"
        ), !refresh.isEmpty else {
            throw ManagerError.notSignedIn
        }
        if let rawRefreshExpiry = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: "workbuddy-refresh-expiry"
        ), let refreshExpiry = TimeInterval(rawRefreshExpiry),
           refreshExpiry <= Date().timeIntervalSince1970 {
            throw ManagerError.refreshExpired
        }

        let domain = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: "workbuddy-domain"
        )
        let token = try await WorkBuddyChinaOAuthFlow.refreshToken(refresh, domain: domain)
        ProviderKeychainHelper.saveOAuthString(
            token.accessToken, instanceId: instanceId, account: "manual-oauth-token"
        )
        let newExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn ?? 3600))
        ProviderKeychainHelper.saveOAuthString(
            String(newExpiry.timeIntervalSince1970),
            instanceId: instanceId, account: "workbuddy-access-expiry"
        )
        if let rotated = token.refreshToken, !rotated.isEmpty {
            ProviderKeychainHelper.saveOAuthString(
                rotated, instanceId: instanceId, account: "workbuddy-refresh-token"
            )
        }
        if let seconds = token.refreshExpiresIn {
            let newRefreshExpiry = Date().addingTimeInterval(TimeInterval(seconds))
            ProviderKeychainHelper.saveOAuthString(
                String(newRefreshExpiry.timeIntervalSince1970),
                instanceId: instanceId, account: "workbuddy-refresh-expiry"
            )
        }
        if let newDomain = token.domain, !newDomain.isEmpty {
            ProviderKeychainHelper.saveOAuthString(
                newDomain, instanceId: instanceId, account: "workbuddy-domain"
            )
        }
        return token.accessToken
    }
}
