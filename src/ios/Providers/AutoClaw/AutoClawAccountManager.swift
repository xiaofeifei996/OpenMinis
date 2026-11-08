import Foundation

/// Keychain account names for the AutoClaw credential store.
///
/// Top-level (not nested in the `@MainActor` manager) because the keys are read
/// from non-isolated UI helpers; a nested type would drag the actor isolation
/// into those call sites.
///
/// The access token deliberately does NOT live in `manual-oauth-token`: that
/// slot means "a bearer the user pasted by hand" everywhere else in the app, so
/// a pasted token stays distinguishable from a real sign-in and keeps winning
/// over it.
enum AutoClawKeychain {
    static let access = "autoclaw-access-token"
    static let refresh = "autoclaw-refresh-token"
    static let expiry = "autoclaw-access-expiry"
    static let deviceID = "autoclaw-device-id"
    static let phone = "autoclaw-phone"
}

/// Keeps AutoClaw credentials usable for outgoing requests.
///
/// Same shape as the other per-instance OAuth managers here: a 5-minute refresh
/// buffer and one in-flight refresh Task per instance, because the upstream
/// rotates `refresh_token` — two concurrent refreshes would present the same
/// token twice and one of them would land on a dead credential.
@MainActor
final class AutoClawAccountManager {
    static let shared = AutoClawAccountManager()
    private init() {}

    private let logger = AppLogger(category: "AutoClaw")
    private let refreshBuffer: TimeInterval = 5 * 60

    private var inFlightRefresh: [String: Task<String, Error>] = [:]

    enum ManagerError: LocalizedError {
        case notSignedIn

        var errorDescription: String? {
            "AutoClaw 尚未登录，请重新登录。"
        }
    }

    // MARK: - Status

    func isAuthenticated(instanceId: String) -> Bool {
        ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: AutoClawKeychain.access
        )?.isEmpty == false
    }

    func maskedToken(instanceId: String) -> String? {
        guard let token = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: AutoClawKeychain.access
        ), token.count > 8 else { return nil }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }

    /// 手机号尾号展示（`138****8000`），登录成功后由 sheet 写入。
    func maskedPhone(instanceId: String) -> String? {
        ProviderKeychainHelper.loadOAuthString(instanceId: instanceId, account: AutoClawKeychain.phone)
    }

    func logout(instanceId: String) {
        inFlightRefresh[instanceId]?.cancel()
        inFlightRefresh[instanceId] = nil
        for account in [AutoClawKeychain.access, AutoClawKeychain.refresh,
                        AutoClawKeychain.expiry, AutoClawKeychain.phone] {
            ProviderKeychainHelper.deleteOAuthString(instanceId: instanceId, account: account)
        }
        // device_id 故意保留：同一台设备重复登录时应继续用同一个 id。
        logger.info("logout instanceId=\(instanceId.prefix(8))")
    }

    // MARK: - Sign-in

    /// Persist the result of a successful SMS sign-in.
    func store(
        _ credentials: AutoClawAPI.Credentials,
        instanceId: String,
        phoneTail: String?
    ) {
        ProviderKeychainHelper.saveOAuthString(
            credentials.accessToken, instanceId: instanceId, account: AutoClawKeychain.access)
        if !credentials.refreshToken.isEmpty {
            ProviderKeychainHelper.saveOAuthString(
                credentials.refreshToken, instanceId: instanceId, account: AutoClawKeychain.refresh)
        }
        if let expiresAt = credentials.expiresAt {
            ProviderKeychainHelper.saveOAuthString(
                String(expiresAt), instanceId: instanceId, account: AutoClawKeychain.expiry)
        } else {
            ProviderKeychainHelper.deleteOAuthString(instanceId: instanceId, account: AutoClawKeychain.expiry)
        }
        if !credentials.deviceID.isEmpty {
            ProviderKeychainHelper.saveOAuthString(
                credentials.deviceID, instanceId: instanceId, account: AutoClawKeychain.deviceID)
        }
        if let phoneTail, !phoneTail.isEmpty {
            ProviderKeychainHelper.saveOAuthString(
                phoneTail, instanceId: instanceId, account: AutoClawKeychain.phone)
        }
        logger.info("signed in instanceId=\(instanceId.prefix(8))")
    }

    // MARK: - Token

    func validAccessToken(instanceId: String, forceRefresh: Bool = false) async throws -> String {
        guard let access = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: AutoClawKeychain.access
        ), !access.isEmpty else {
            throw ManagerError.notSignedIn
        }
        if !forceRefresh {
            let expiry = ProviderKeychainHelper.loadOAuthString(
                instanceId: instanceId, account: AutoClawKeychain.expiry
            ).flatMap(TimeInterval.init)
            if let expiry, expiry > Date().timeIntervalSince1970 + refreshBuffer {
                return access
            }
        }
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

    private func performRefresh(instanceId: String) async throws -> String {
        guard let refresh = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: AutoClawKeychain.refresh
        ), !refresh.isEmpty else {
            throw ManagerError.notSignedIn
        }
        let deviceID = ProviderKeychainHelper.loadOAuthString(
            instanceId: instanceId, account: AutoClawKeychain.deviceID)
        // 自定义 Base URL 可能是国际站（同一个协议、不同域名），刷新也要跟着走。
        let root = ProviderConfigStore.shared.instance(for: instanceId)?.effectiveCustomBaseURL

        let result: (accessToken: String, refreshToken: String?)
        do {
            result = try await AutoClawAPI.refresh(refreshToken: refresh, deviceID: deviceID, root: root)
        } catch AutoClawAPI.FlowError.expired {
            // 刷新令牌本身作废：留着只会让后面每个请求都撞同一个错误。
            logout(instanceId: instanceId)
            throw AutoClawAPI.FlowError.expired
        }

        ProviderKeychainHelper.saveOAuthString(
            result.accessToken, instanceId: instanceId, account: AutoClawKeychain.access)
        if let rotated = result.refreshToken, !rotated.isEmpty {
            ProviderKeychainHelper.saveOAuthString(
                rotated, instanceId: instanceId, account: AutoClawKeychain.refresh)
        }
        if let expiry = AutoClawJWT.expiry(result.accessToken) {
            ProviderKeychainHelper.saveOAuthString(
                String(expiry), instanceId: instanceId, account: AutoClawKeychain.expiry)
        } else {
            ProviderKeychainHelper.deleteOAuthString(instanceId: instanceId, account: AutoClawKeychain.expiry)
        }
        logger.info("refreshed instanceId=\(instanceId.prefix(8)) rotated=\(result.refreshToken != nil)")
        return result.accessToken
    }
}
