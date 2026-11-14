import Foundation
import CryptoKit
import Security
import UIKit
import SafariServices

/// Trae's browser sign-in.
///
/// Not OAuth 2.0 despite the shape: the page hands back an `authCodeInfo` blob
/// instead of a `code`, and the exchange is Trae's own endpoint. Hoping a
/// generic helper would cover it costs a day of guessing at which parameter the
/// page silently refuses, so the flow is written out.
///
/// The parameter set below is the client's own, in its order. A page given one
/// parameter too few sits on "authenticating" forever: no error, no callback.
/// `client_id` is snake_case here and `ClientID` PascalCase in the exchange
/// body, and `DeviceInfo.DevicePublicKey` must be a real EC P-256 SPKI PEM — an
/// empty string answers `400 invalid parameter`.
enum TraeSignIn {
    struct Credentials: Sendable {
        var accessToken: String
        var refreshToken: String
        var userID: String
        var machineID: String
        var deviceID: String
        /// The account gate that accepted this sign-in; renewals go to it,
        /// because the international build has several and only one serves the
        /// account.
        var gate: String
        var site: TraeAPI.Site
        var expiresAt: Double?
    }

    enum FlowError: LocalizedError {
        case noSignInHost(String)
        case noAuthCode
        case wrongBuild
        case server(String)

        var errorDescription: String? {
            switch self {
            case .noSignInHost(let detail):
                return "找不到 Trae 登录页。\(detail)"
            case .noAuthCode:
                return "Trae 页面没有返回登录凭证，请重试。"
            case .wrongBuild:
                return "Trae 登录未完成：账号与所选的版本不匹配。"
            case .server(let message):
                return message
            }
        }
    }

    // MARK: - Sign-in

    /// Sign in, trying both builds.
    ///
    /// The two builds' accounts do not cross over (a China credential traded on
    /// an international gate answers `20101`), and the user should not have to
    /// know which build their account belongs to. So the flow asks each build's
    /// sign-in page in turn and stops at the one that accepts the account.
    @MainActor
    static func signIn(session: URLSession = .shared) async throws -> Credentials {
        var lastError: Error?
        // China first: it is the more common case here and its page is a fixed
        // host, so a wrong guess costs one page load rather than a failed login.
        for site in [TraeAPI.Site.china, .international] {
            do {
                return try await signIn(site: site, session: session)
            } catch let error as FlowError {
                if case .wrongBuild = error {
                    lastError = error
                    continue
                }
                throw error
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? FlowError.server("Trae 登录未完成。")
    }

    @MainActor
    static func signIn(site: TraeAPI.Site, session: URLSession = .shared) async throws -> Credentials {
        // Port 0 = "any free port"; the redirect must name the real one, which
        // the server reports after binding.
        let server = OAuthCallbackServer(port: 0, callbackPath: "/authorize", requiresCode: false)
        try server.start()
        defer { server.stop() }
        let redirect = "http://127.0.0.1:\(server.boundPort)/authorize"

        let pkce = TraePKCE.generate()
        let machineID = site.machineIsUUID ? UUID().uuidString : randomHex(bytes: 32)
        let deviceID = site.fixedDeviceID ?? randomDeviceID()
        let loginTraceID = UUID().uuidString

        let loginHost = try await signInHost(site: site, loginTraceID: loginTraceID, session: session)
        let page = try loginURL(
            loginHost: loginHost,
            redirect: redirect,
            machineID: machineID,
            deviceID: deviceID,
            loginTraceID: loginTraceID,
            pkce: pkce,
            site: site
        )

        try Task.checkCancellation()
        try presentInSafari(page)
        // Defer dismissal until the flow has consumed the callback and exchange.
        // Safari can finish immediately after following the loopback redirect.
        defer { Task { @MainActor in dismissSignInPage() } }
        let callback = try await server.waitForCallback(timeout: 5 * 60)
        try Task.checkCancellation()

        if let error = callback.query["error"], !error.isEmpty {
            throw FlowError.server("Trae 登录失败：\(error)")
        }
        let payload = try callbackPayload(callback.query)
        guard payload.loginTraceID.isEmpty || payload.loginTraceID == loginTraceID else {
            throw FlowError.server("Trae 登录回调属于另一次登录，请重试。")
        }
        try Task.checkCancellation()
        let exchanged = try await exchange(
            authCode: payload.authCode,
            codeVerifier: pkce.verifier,
            machineID: machineID,
            deviceID: deviceID,
            site: site,
            session: session
        )

        return Credentials(
            accessToken: exchanged.access,
            refreshToken: exchanged.refresh,
            userID: payload.userID.isEmpty ? jwtUserID(exchanged.access) : payload.userID,
            machineID: machineID,
            deviceID: deviceID,
            gate: exchanged.origin,
            site: site,
            expiresAt: exchanged.expires
        )
    }

    // MARK: - Renewal

    static func renew(
        refreshToken: String,
        userID: String,
        gate: String,
        session: URLSession = .shared
    ) async throws -> (access: String, refresh: String, expiresAt: Double?) {
        guard let url = URL(string: gate + TraeAPI.renewalPath) else {
            throw FlowError.server("Trae 刷新地址无法读取。")
        }
        // The renewal is a different endpoint from the sign-in, and its body
        // carries ClientSecret ("-") plus UserID — the exchange refuses those.
        let body: [String: Any] = [
            "ClientID": TraeAPI.clientID,
            "RefreshToken": refreshToken,
            "ClientSecret": "-",
            "UserID": userID,
        ]
        let (response, data) = try await postJSON(url: url, body: body, session: session)
        guard response.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FlowError.server("Trae 令牌刷新失败（HTTP \(response.statusCode)）。")
        }
        let result = (root["Result"] ?? root["result"]) as? [String: Any] ?? root
        guard let access = TraeAPI.firstString(result, ["Token", "token", "AccessToken", "access_token"]),
              !access.isEmpty else {
            throw FlowError.server("Trae 令牌刷新失败：服务器未返回新令牌。")
        }
        let refresh = TraeAPI.firstString(result, ["RefreshToken", "refreshToken"]) ?? refreshToken
        return (access, refresh, expiry(result["TokenExpireAt"] ?? result["tokenExpireAt"]))
    }

    // MARK: - Sign-in page

    private static func signInHost(
        site: TraeAPI.Site,
        loginTraceID: String,
        session: URLSession
    ) async throws -> String {
        if let fixed = site.fixedLoginHost { return fixed }
        var failures: [String] = []
        for address in site.guidanceURLs {
            guard let url = URL(string: address) else { continue }
            do {
                let (response, data) = try await postJSON(
                    url: url,
                    body: ["loginTraceID": loginTraceID, "login_trace_id": loginTraceID],
                    session: session
                )
                guard response.statusCode == 200,
                      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let host = guidanceHost(root), !host.isEmpty else {
                    failures.append("\(address): 未返回登录页地址")
                    continue
                }
                return host
            } catch {
                failures.append("\(address): \(error.localizedDescription)")
            }
        }
        throw FlowError.noSignInHost(failures.joined(separator: " · "))
    }

    private static func guidanceHost(_ root: [String: Any]) -> String? {
        for key in ["Result", "result", "data"] {
            if let layer = root[key] as? [String: Any],
               let host = TraeAPI.firstString(layer, ["LoginHost", "loginHost", "LoginURL", "loginUrl"]) {
                return host
            }
        }
        return TraeAPI.firstString(root, ["LoginHost", "loginHost", "loginUrl"])
    }

    /// `<host>/authorization?<query>`, parameters in the client's own order.
    private static func loginURL(
        loginHost: String,
        redirect: String,
        machineID: String,
        deviceID: String,
        loginTraceID: String,
        pkce: TraePKCE,
        site: TraeAPI.Site
    ) throws -> URL {
        guard let origin = origin(of: loginHost),
              var components = URLComponents(string: origin + "/authorization") else {
            throw FlowError.server("Trae 登录页地址无法读取。")
        }
        var items = [
            URLQueryItem(name: "login_version", value: "1"),
            URLQueryItem(name: "auth_from", value: "trae"),
            URLQueryItem(name: "login_channel", value: "native_ide"),
            URLQueryItem(name: "plugin_version", value: site.pluginVersion),
            URLQueryItem(name: "auth_type", value: "local"),
            URLQueryItem(name: "client_id", value: TraeAPI.clientID),
            URLQueryItem(name: "redirect", value: "0"),
            URLQueryItem(name: "login_trace_id", value: loginTraceID),
            URLQueryItem(name: "auth_callback_url", value: redirect),
            URLQueryItem(name: "machine_id", value: machineID),
            URLQueryItem(name: "device_id", value: deviceID),
            URLQueryItem(name: "x_device_id", value: deviceID),
            URLQueryItem(name: "x_machine_id", value: machineID),
            URLQueryItem(name: "x_device_brand", value: site.deviceBrand),
            URLQueryItem(name: "x_device_type", value: site.osInfo),
            URLQueryItem(name: "x_os_version", value: site.osVersion),
            URLQueryItem(name: "x_env", value: ""),
            URLQueryItem(name: "x_app_version", value: site.appVersion),
            URLQueryItem(name: "x_app_type", value: "stable"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let channelName = site.channelName {
            items.append(URLQueryItem(name: "channel_name", value: channelName))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw FlowError.server("Trae 登录地址无法构造。")
        }
        return url
    }

    // MARK: - Callback

    private struct Callback {
        var authCode: String
        var userID: String
        var loginTraceID: String
    }

    /// The page is dual-mode: with a `code_challenge` it returns `authCodeInfo`
    /// for the client to exchange; without one it returns `refreshToken`
    /// directly. This flow always sends PKCE, so a callback with no auth code is
    /// a real failure rather than a second flow.
    private static func callbackPayload(_ query: [String: String]) throws -> Callback {
        guard let raw = query["authCodeInfo"], !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let authCode = TraeAPI.firstString(object, ["AuthCode", "authCode"]),
              !authCode.isEmpty else {
            if let code = query["code"], !code.isEmpty {
                return Callback(authCode: code, userID: "", loginTraceID: query["loginTraceID"] ?? "")
            }
            throw FlowError.noAuthCode
        }
        var userID = ""
        if let raw = query["userInfo"], !raw.isEmpty,
           let data = raw.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            userID = TraeAPI.firstString(object, ["UserID", "UserId", "userId"]) ?? ""
        }
        return Callback(
            authCode: authCode,
            userID: userID,
            loginTraceID: query["loginTraceID"] ?? ""
        )
    }

    // MARK: - Exchange

    private struct Exchanged {
        var access: String
        var refresh: String
        var expires: Double?
        var origin: String
    }

    /// `POST <gate>/trae/api/v3/oauth/ExchangeToken` — the five fields the
    /// client sends, no `ClientSecret` and no `DeviceProof` (both belong to the
    /// renewal path and this endpoint refuses them).
    private static func exchange(
        authCode: String,
        codeVerifier: String,
        machineID: String,
        deviceID: String,
        site: TraeAPI.Site,
        session: URLSession
    ) async throws -> Exchanged {
        let body: [String: Any] = [
            "ClientID": TraeAPI.clientID,
            "AuthCode": authCode,
            "CodeVerifier": codeVerifier,
            "DeviceInfo": deviceInfo(machineID: machineID, deviceID: deviceID, site: site),
            "IDEVersion": site.appVersion,
        ]
        var failures: [String] = []
        var wrongBuild = false
        for origin in site.exchangeOrigins {
            guard let url = URL(string: origin + TraeAPI.authExchangePath) else { continue }
            do {
                let (response, data) = try await postJSON(url: url, body: body, session: session)
                guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    failures.append("\(origin): 响应无法解析（HTTP \(response.statusCode)）")
                    continue
                }
                if let failure = envelopeError(root) {
                    if failure.contains("20101") { wrongBuild = true }
                    failures.append("\(origin): \(failure)")
                    continue
                }
                guard response.statusCode == 200 else {
                    failures.append("\(origin): HTTP \(response.statusCode)")
                    continue
                }
                let result = (root["Result"] ?? root["result"]) as? [String: Any] ?? root
                guard let access = TraeAPI.firstString(
                    result, ["Token", "token", "AccessToken", "access_token"]
                ), !access.isEmpty else {
                    failures.append("\(origin): 未返回令牌")
                    continue
                }
                return Exchanged(
                    access: access,
                    refresh: TraeAPI.firstString(result, ["RefreshToken", "refreshToken"]) ?? "",
                    expires: expiry(result["TokenExpireAt"] ?? result["tokenExpireAt"]),
                    origin: origin
                )
            } catch {
                failures.append("\(origin): \(error.localizedDescription)")
            }
        }
        if wrongBuild { throw FlowError.wrongBuild }
        throw FlowError.server("Trae 登录未完成。\(failures.joined(separator: " · "))")
    }

    /// The twelve fields the client sends, in its order.
    private static func deviceInfo(machineID: String, deviceID: String, site: TraeAPI.Site) -> [String: Any] {
        [
            "DeviceID": deviceID,
            "MachineID": machineID,
            "PlatformCode": "IDE_PC",
            "DeviceType": "PC",
            "DeviceName": UIDevice.current.name,
            "DeviceModel": site.deviceBrand,
            "ClientVersion": site.appVersion,
            "DevicePublicKey": P256.Signing.PrivateKey().publicKey.pemRepresentation,
            "DeviceBrand": site.deviceBrand,
            "DeviceCPU": "",
            "OSInfo": site.osInfo,
            "OSVersion": site.osVersion,
        ]
    }

    // MARK: - Browser

    @MainActor
    private static func presentInSafari(_ url: URL) throws {
        guard let root = topViewController() else {
            throw FlowError.server("无法打开 Trae 登录页。")
        }
        let safari = SFSafariViewController(url: url)
        safari.dismissButtonStyle = .cancel
        root.present(safari, animated: true)
    }

    @MainActor
    static func dismissSignInPage() {
        guard let top = topViewController(), top is SFSafariViewController else { return }
        top.dismiss(animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: \.isKeyWindow)?
            .rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    // MARK: - Helpers

    private static func postJSON(
        url: URL,
        body: [String: Any],
        session: URLSession
    ) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse ?? HTTPURLResponse()
        return (http, data)
    }

    /// Trae's `{Code, Message}` envelope, either spelling. A body with no code is
    /// a success — some of its services answer that way.
    private static func envelopeError(_ root: [String: Any]) -> String? {
        for key in ["Code", "code", "ErrCode", "errCode"] {
            guard let value = root[key] else { continue }
            let code: Int?
            if let number = value as? NSNumber { code = number.intValue }
            else if let text = value as? String { code = Int(text) }
            else { code = nil }
            guard let code, code != 0 else { continue }
            let message = TraeAPI.firstString(root, ["Message", "message", "Msg", "msg", "ErrMsg"])
            return "\(code) \(message ?? "")"
        }
        return nil
    }

    private static func origin(of address: String) -> String? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty else {
            return nil
        }
        let scheme = components.scheme?.lowercased() ?? "https"
        guard let port = components.port else { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }

    /// Sixteen decimal digits — the shape the China page checks for `device_id`.
    private static func randomDeviceID() -> String {
        (0..<16).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    private static func randomHex(bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, bytes, buffer.baseAddress!)
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func jwtUserID(_ token: String) -> String {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return "" }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ""
        }
        return TraeAPI.firstString(object, ["user_id", "userId", "uid", "sub", "UserID"]) ?? ""
    }

    /// `TokenExpireAt` may be Unix seconds/milliseconds, a numeric string, or
    /// an ISO-8601 date. Absent or malformed means unknown, which remains usable
    /// until an explicit forced refresh.
    static func expiry(_ raw: Any?) -> Double? {
        let value: Double?
        switch raw {
        case let number as NSNumber: value = number.doubleValue
        case let string as String:
            if let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                value = number
            } else if let date = ISO8601DateFormatter().date(from: string) {
                value = date.timeIntervalSince1970
            } else {
                value = nil
            }
        case let date as Date: value = date.timeIntervalSince1970
        default: value = nil
        }
        guard let value, value > 0 else { return nil }
        return value > 1_000_000_000_000 ? value / 1000 : value
    }
}

/// PKCE (RFC 7636, S256).
struct TraePKCE {
    let verifier: String
    let challenge: String

    static func generate() -> TraePKCE {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let verifier = String((0..<64).compactMap { _ in chars.randomElement() })
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return TraePKCE(verifier: verifier, challenge: challenge)
    }
}
