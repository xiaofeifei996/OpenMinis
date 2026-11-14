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
    private struct RefreshFlight {
        let id: UUID
        let identity: [String?]
        let task: Task<String, Error>
    }
    private var inFlight: [String: RefreshFlight] = [:]
    private var signIns: [String: (id: UUID, task: Task<TraeSignIn.Credentials, Error>)] = [:]

    // Keep the existing per-field Keychain format. Include every identity field
    // so an imported credential or a new login wins over an older renewal.
    private static let accounts = [
        TraeKeychain.access, TraeKeychain.refresh, TraeKeychain.expiry,
        TraeKeychain.userID, TraeKeychain.machineID, TraeKeychain.deviceID,
        TraeKeychain.gate, TraeKeychain.site, TraeKeychain.apiOrigin,
    ]

    private func identity(instanceId: String) -> [String?] {
        Self.accounts.map {
            ProviderKeychainHelper.loadOAuthString(instanceId: instanceId, account: $0)
        }
    }

    private func cancelRefresh(instanceId: String) {
        inFlight.removeValue(forKey: instanceId)?.task.cancel()
    }

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

    nonisolated static func resolvedOrigin(instance: ProviderInstance) -> String {
        if let custom = instance.effectiveCustomBaseURL { return custom }
        if instance.providerType == .traeInternational { return TraeAPI.Site.international.apiOrigin }
        if let saved = apiOrigin(instanceId: instance.id), !saved.isEmpty { return saved }
        return TraeAPI.Site.china.apiOrigin
    }

    func logout(instanceId: String) {
        cancelRefresh(instanceId: instanceId)
        signIns.removeValue(forKey: instanceId)?.task.cancel()
        for account in Self.accounts {
            ProviderKeychainHelper.deleteOAuthString(instanceId: instanceId, account: account)
        }
        logger.info("logout instanceId=\(instanceId.prefix(8))")
    }

    // MARK: - Sign-in

    @discardableResult
    func signIn(instanceId: String, site: TraeAPI.Site? = nil) async throws -> String {
        try Task.checkCancellation()
        cancelRefresh(instanceId: instanceId)
        signIns.removeValue(forKey: instanceId)?.task.cancel()
        let loginID = UUID()
        let task = Task { @MainActor in
            if let site { return try await TraeSignIn.signIn(site: site) }
            return try await TraeSignIn.signIn()
        }
        signIns[instanceId] = (loginID, task)
        defer {
            if signIns[instanceId]?.id == loginID { signIns[instanceId] = nil }
        }
        let credentials = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard signIns[instanceId]?.id == loginID else { throw CancellationError() }
        // A request may have started another renewal while the page was open.
        cancelRefresh(instanceId: instanceId)
        ProviderKeychainHelper.saveOAuthString(
            credentials.accessToken, instanceId: instanceId, account: TraeKeychain.access)
        if !credentials.refreshToken.isEmpty {
            ProviderKeychainHelper.saveOAuthString(
                credentials.refreshToken, instanceId: instanceId, account: TraeKeychain.refresh)
        } else {
            ProviderKeychainHelper.deleteOAuthString(instanceId: instanceId, account: TraeKeychain.refresh)
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
        ] {
            if value.isEmpty {
                ProviderKeychainHelper.deleteOAuthString(instanceId: instanceId, account: account)
            } else {
                ProviderKeychainHelper.saveOAuthString(value, instanceId: instanceId, account: account)
            }
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

    func validAccessToken(
        instanceId: String,
        expectedSite: TraeAPI.Site? = nil,
        forceRefresh: Bool = false
    ) async throws -> String {
        try Task.checkCancellation()
        // Check even when the token is fresh or a renewal is already running:
        // an explicit international provider must never send a saved CN token.
        let storedSite = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: TraeKeychain.site)
        if let expectedSite, storedSite != expectedSite.rawValue {
            throw TraeSignIn.FlowError.wrongBuild
        }
        guard let access = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: TraeKeychain.access
        ), !access.isEmpty else {
            throw ManagerError.notSignedIn
        }
        let snapshot = identity(instanceId: instanceId)
        if let existing = inFlight[instanceId] {
            if existing.identity == snapshot {
                let token = try await existing.task.value
                try Task.checkCancellation()
                return token
            }
            cancelRefresh(instanceId: instanceId)
        }
        let expiry = TraeSignIn.expiry(ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: TraeKeychain.expiry))
        if !forceRefresh, expiry == nil || expiry! > Date().timeIntervalSince1970 + refreshBuffer {
            return access
        }
        // Pasted tokens without renewal credentials remain usable as before;
        // an explicit forced renewal must report that it cannot renew them.
        guard let refresh = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: TraeKeychain.refresh
        ), !refresh.isEmpty else {
            if forceRefresh { throw ManagerError.notSignedIn }
            return access
        }
        let site: TraeAPI.Site
        if let storedSite, !storedSite.isEmpty {
            guard let parsed = TraeAPI.Site(rawValue: storedSite) else {
                throw TraeSignIn.FlowError.wrongBuild
            }
            site = parsed
        } else {
            site = .china // Legacy records predate the site field.
        }
        let userID = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: TraeKeychain.userID) ?? ""
        let gate = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: TraeKeychain.gate)
        let origin = gate.flatMap { $0.isEmpty ? nil : $0 } ?? site.exchangeOrigins[0]
        guard site.exchangeOrigins.contains(origin) else {
            throw TraeSignIn.FlowError.server("Trae 已保存的登录网关与账号版本不匹配，请重新登录。")
        }
        let flightID = UUID()
        let task = Task<String, Error> {
            // Let the creator publish the flight before the first identity check.
            await Task.yield()
            try Task.checkCancellation()
            guard self.inFlight[instanceId]?.id == flightID,
                  self.identity(instanceId: instanceId) == snapshot else {
                throw CancellationError()
            }
            // Network/server failures leave the current credential intact.
            let renewed = try await TraeSignIn.renew(
                refreshToken: refresh, userID: userID, gate: origin)
            try Task.checkCancellation()
            guard self.inFlight[instanceId]?.id == flightID,
                  self.identity(instanceId: instanceId) == snapshot else {
                throw CancellationError()
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
            } else {
                ProviderKeychainHelper.deleteOAuthString(instanceId: instanceId, account: TraeKeychain.expiry)
            }
            self.logger.info("renewed instanceId=\(instanceId.prefix(8))")
            return renewed.access
        }
        inFlight[instanceId] = RefreshFlight(id: flightID, identity: snapshot, task: task)
        defer {
            // An older waiter must not remove a newer flight after re-login.
            if inFlight[instanceId]?.id == flightID { inFlight[instanceId] = nil }
        }
        let token = try await task.value
        try Task.checkCancellation()
        return token
    }
}
