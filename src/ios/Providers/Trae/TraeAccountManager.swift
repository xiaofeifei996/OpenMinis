import Foundation

/// Keychain account names for a Trae sign-in.
///
/// Top-level for the same reason as the other channels' key enums: the keys are
/// read from non-isolated helpers, and nesting them in the `@MainActor` manager
/// would drag actor isolation into those call sites.
enum TraeKeychain {
    static let access = "trae-access-token"
    static let refresh = "trae-refresh-token"
    static let expiry = "trae-access-expiry"
    static let userID = "trae-user-id"
    static let machineID = "trae-machine-id"
    static let deviceID = "trae-device-id"
    /// The account gate that accepted the sign-in; renewals must go to it.
    static let gate = "trae-oauth-host"
    /// The build this account belongs to (`china` / `international`).
    static let site = "trae-site"
    /// Where chat goes for this account (the two builds differ).
    static let apiOrigin = "trae-api-origin"
}

/// Keeps a Trae sign-in usable for outgoing requests.
///
/// Same shape as the other per-instance managers: a 5-minute refresh buffer and
/// one in-flight renewal per instance, because the exchange rotates the refresh
/// token — two concurrent renewals would present the same token twice and lock
/// the account out.
@MainActor
final class TraeAccountManager {
    static let shared = TraeAccountManager()
    private init() {}

    private let logger = AppLogger(category: "Trae")
    private let refreshBuffer: TimeInterval = 5 * 60
    private var inFlight: [String: Task<String, Error>] = [:]

    enum ManagerError: LocalizedError {
        case notSignedIn

        var errorDescription: String? { "Trae 尚未登录，请重新登录。" }
    }

    // MARK: - Status

    func isAuthenticated(instanceId: String) -> Bool {
        ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: TraeKeychain.access
        )?.isEmpty == false
    }

    func maskedToken(instanceId: String) -> String? {
        guard let token = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: TraeKeychain.access
        ), token.count > 8 else { return nil }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }

    /// Where chat for this account goes: whatever the sign-in recorded, so an
    /// international account does not send its token to the China host.
    ///
    /// `nonisolated static` because the provider factory reads it while building
    /// a request, off the main actor; a Keychain read needs no actor.
    nonisolated static func apiOrigin(instanceId: String) -> String? {
        ProviderKeychainHelper.loadOAuthString(instanceId: instanceId, account: TraeKeychain.apiOrigin)
    }

    func logout(instanceId: String) {
        inFlight[instanceId]?.cancel()
        inFlight[instanceId] = nil
        for account in [TraeKeychain.access, TraeKeychain.refresh, TraeKeychain.expiry,
                        TraeKeychain.userID, TraeKeychain.machineID, TraeKeychain.deviceID,
                        TraeKeychain.gate, TraeKeychain.site, TraeKeychain.apiOrigin] {
            ProviderKeychainHelper.deleteOAuthString(instanceId: instanceId, account: account)
        }
        logger.info("logout instanceId=\(instanceId.prefix(8))")
    }

    // MARK: - Sign-in

    @discardableResult
    func signIn(instanceId: String) async throws -> String {
        let credentials = try await TraeSignIn.signIn()
        ProviderKeychainHelper.saveOAuthString(
            credentials.accessToken, instanceId: instanceId, account: TraeKeychain.access)
        if !credentials.refreshToken.isEmpty {
            ProviderKeychainHelper.saveOAuthString(
                credentials.refreshToken, instanceId: instanceId, account: TraeKeychain.refresh)
        }
        if let expiresAt = credentials.expiresAt {
            ProviderKeychainHelper.saveOAuthString(
                String(expiresAt), instanceId: instanceId, account: TraeKeychain.expiry)
        } else {
            ProviderKeychainHelper.deleteOAuthString(instanceId: instanceId, account: TraeKeychain.expiry)
        }
        for (value, account) in [
            (credentials.userID, TraeKeychain.userID),
            (credentials.machineID, TraeKeychain.machineID),
            (credentials.deviceID, TraeKeychain.deviceID),
            (credentials.gate, TraeKeychain.gate),
            (credentials.site.rawValue, TraeKeychain.site),
            (credentials.site.apiOrigin, TraeKeychain.apiOrigin),
        ] where !value.isEmpty {
            ProviderKeychainHelper.saveOAuthString(value, instanceId: instanceId, account: account)
        }
        logger.info("signed in instanceId=\(instanceId.prefix(8)) site=\(credentials.site.rawValue)")
        return credentials.accessToken
    }

    /// The ids a request has to echo back. Empty for a pasted token, in which
    /// case they are derived from the account instead.
    ///
    /// `nonisolated` on purpose: the request builder calls this from wherever the
    /// stream runs, and Keychain reads are thread-safe, so fencing it to the
    /// main actor would either crash an `assumeIsolated` or serialize every
    /// request behind the main queue.
    nonisolated static func extraHeaderValues(
        instanceId: String
    ) -> (machineID: String?, deviceID: String?, userID: String?) {
        (
            ProviderKeychainHelper.loadOAuthString(instanceId: instanceId, account: TraeKeychain.machineID),
            ProviderKeychainHelper.loadOAuthString(instanceId: instanceId, account: TraeKeychain.deviceID),
            ProviderKeychainHelper.loadOAuthString(instanceId: instanceId, account: TraeKeychain.userID)
        )
    }

    // MARK: - Token

    func validAccessToken(instanceId: String) async throws -> String {
        guard let access = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: TraeKeychain.access
        ), !access.isEmpty else {
            throw ManagerError.notSignedIn
        }
        let expiry = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: TraeKeychain.expiry
        ).flatMap(TimeInterval.init)
        if let expiry, expiry > Date().timeIntervalSince1970 + refreshBuffer {
            return access
        }
        // A pasted token has no refresh token; hand it back as-is and let the
        // upstream decide. Renewing is impossible here rather than failed.
        guard let refresh = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: TraeKeychain.refresh
        ), !refresh.isEmpty else {
            return access
        }
        if let existing = inFlight[instanceId] { return try await existing.value }
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw ManagerError.notSignedIn }
            return try await self.performRefresh(instanceId: instanceId, refreshToken: refresh)
        }
        inFlight[instanceId] = task
        defer { inFlight[instanceId] = nil }
        return try await task.value
    }

    private func performRefresh(instanceId: String, refreshToken: String) async throws -> String {
        let userID = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: TraeKeychain.userID) ?? ""
        let gate = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: TraeKeychain.gate)
        let fallback = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: TraeKeychain.site) == "international"
            ? TraeAPI.Site.international : .china
        let origin = gate.flatMap { $0.isEmpty ? nil : $0 } ?? fallback.exchangeOrigins[0]

        let renewed: (access: String, refresh: String, expiresAt: Double?)
        do {
            renewed = try await TraeSignIn.renew(
                refreshToken: refreshToken, userID: userID, gate: origin)
        } catch {
            // The refresh token is dead; keeping it would make every later
            // request fail with the same error.
            logout(instanceId: instanceId)
            throw error
        }
        ProviderKeychainHelper.saveOAuthString(
            renewed.access, instanceId: instanceId, account: TraeKeychain.access)
        if !renewed.refresh.isEmpty {
            ProviderKeychainHelper.saveOAuthString(
                renewed.refresh, instanceId: instanceId, account: TraeKeychain.refresh)
        }
        if let expiresAt = renewed.expiresAt {
            ProviderKeychainHelper.saveOAuthString(
                String(expiresAt), instanceId: instanceId, account: TraeKeychain.expiry)
        }
        logger.info("renewed instanceId=\(instanceId.prefix(8))")
        return renewed.access
    }
}
