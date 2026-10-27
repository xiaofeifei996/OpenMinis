import Foundation

/// Keeps WorkBuddy China OAuth credentials usable for outgoing model requests.
/// Concurrent requests for the same instance share a single refresh operation.
@MainActor
final class WorkBuddyChinaOAuthManager {
    static let shared = WorkBuddyChinaOAuthManager()
    private init() {}

    private var refreshTasks: [String: Task<String, Error>] = [:]

    enum ManagerError: LocalizedError {
        case notSignedIn
        case refreshExpired

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Sign in to WorkBuddy China again to continue."
            case .refreshExpired:
                return "Your WorkBuddy China session expired. Please sign in again."
            }
        }
    }

    func validAccessToken(instanceId: String) async throws -> String {
        guard let access = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: "manual-oauth-token"
        ), !access.isEmpty else {
            throw ManagerError.notSignedIn
        }

        let expiryString = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: "workbuddy-access-expiry"
        )
        if let expiry = expiryString.flatMap(TimeInterval.init),
           expiry > Date().timeIntervalSince1970 + 300 {
            return access
        }

        // Actor isolation alone does not serialize across await points.
        // Keep and await one shared task so concurrent callers do not rotate
        // the same refresh token simultaneously.
        if let existing = refreshTasks[instanceId] {
            return try await existing.value
        }

        let task = Task<String, Error> { [weak self] in
            guard let self else { throw ManagerError.notSignedIn }
            return try await self.performRefresh(instanceId: instanceId)
        }
        refreshTasks[instanceId] = task
        do {
            let refreshed = try await task.value
            refreshTasks[instanceId] = nil
            return refreshed
        } catch {
            refreshTasks[instanceId] = nil
            throw error
        }
    }

    private func performRefresh(instanceId: String) async throws -> String {
        guard let refresh = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: "workbuddy-refresh-token"
        ), !refresh.isEmpty else {
            throw ManagerError.notSignedIn
        }

        if let rawExpiry = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: "workbuddy-refresh-expiry"
        ), let expiry = TimeInterval(rawExpiry),
           expiry <= Date().timeIntervalSince1970 {
            throw ManagerError.refreshExpired
        }

        let domain = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: "workbuddy-domain"
        )
        let token = try await WorkBuddyChinaOAuthFlow.refreshToken(refresh, domain: domain)

        guard !token.accessToken.isEmpty else {
            throw WorkBuddyChinaOAuthFlow.FlowError.missingToken
        }
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
