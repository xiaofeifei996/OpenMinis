import Foundation
import CryptoKit
import Security

/// AutoClaw (智谱 AutoGLM 桌面端) gateway protocol.
///
/// The desktop client talks to its own gateway, not to Z.ai's public API, and
/// that gateway validates the request in three places that are easy to get
/// wrong. All three are handled here so the rest of the app never has to
/// know about them:
///
/// 1. **Auth header name.** The LLM domain reads `X-Authorization`, not
///    `Authorization`, and it sends neither `X-Harness-Type` nor `X-Tm: linux`.
/// 2. **System prompt identity.** The first system/developer message must open
///    with the client's identity sentence *and* carry a `## Tooling` heading;
///    anything else answers an empty `406` with no body at all.
/// 3. **`max_tokens` floor.** A positive value below 10000 is rejected with the
///    same bodyless 406, so small values are lifted to the floor.
///
/// Token refresh is signed with `MD5(appId & unixSeconds & appKey)` — the
/// signature lives on the *user API* domain only.
enum AutoClawAPI {
    /// 国内（智谱加速站）. 国际版是 `https://autoglm-api.autoglm.ai`，同一个协议，
    /// 用自定义 Base URL 切换即可。
    static let defaultBase = "https://autoglm-acceleration-api.zhipuai.cn"
    static let internationalBase = "https://autoglm-api.autoglm.ai"

    static let llmPath = "/autoclaw-proxy/proxy/autoclaw"
    static let catalogPath = "/autoclaw-proxy/proxy/autoclaw-model-config"
    static let sendCodePath = "/userapi/v1/agent-send-code"
    /// 结尾斜杠是上游要求，去掉会 404。
    static let loginPath = "/userapi/v1/agent-login/"
    static let refreshPath = "/userapi/v1/refresh"
    /// `refreshPath` 签名被拒（业务码 400002）时的降级端点。
    static let refreshFallbackPath = "/userapi/v1/agent-refresh"

    static let authAppID = "100003"
    static let authAppKey = "38d2391985e2369a5fb8227d8e6cd5e5"
    static let clientVersion = "2.2.0"
    static let userAgent = "AutoClaw/\(clientVersion)"

    /// `max_tokens` 下界：0 < v < 10000 一律 406。
    static let maxTokensFloor = 10000

    static let identityLine = "You are a personal assistant running inside OpenClaw."
    static let identityPrefix = """
    You are a personal assistant running inside OpenClaw.

    ## Tooling
    Available tools are policy-filtered. Names are case-sensitive; call exactly as listed.

    """

    // MARK: - URLs

    /// The configured value is the *site root*; the LLM proxy path is appended
    /// here so a user pointing at the international host only swaps the root.
    static func llmBase(root: String?) -> String {
        normalizeRoot(root) + llmPath
    }

    static func normalizeRoot(_ raw: String?) -> String {
        var s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        // 允许用户把完整 LLM 端点贴进 Base URL：剥回去，保持「根」的唯一语义。
        if s.hasSuffix(llmPath) { s = String(s.dropLast(llmPath.count)) }
        return s.isEmpty ? defaultBase : s
    }

    // MARK: - Signing

    /// `X-Auth-Sign` = MD5(`${appId}&${秒级时间戳}&${appKey}`) 小写十六进制。
    /// 时间戳用秒：毫秒会被上游判 400002。
    static func authSignature(now: Date = Date()) -> (timestamp: String, sign: String) {
        let seconds = String(Int(now.timeIntervalSince1970))
        let material = "\(authAppID)&\(seconds)&\(authAppKey)"
        let digest = Insecure.MD5.hash(data: Data(material.utf8))
        return (seconds, digest.map { String(format: "%02x", $0) }.joined())
    }

    /// userapi 域签名头（刷新 / 目录 / 登录共用）。
    /// `X-Harness-Type: zcode` 是官方客户端指纹的一部分，缺了有 400002 风险；
    /// `X-Tm` 在这里如实发宿主平台，只有 LLM 域禁止 `linux`。
    static func signedHeaders(token: String?) -> [String: String] {
        let (ts, sign) = authSignature()
        var headers: [String: String] = [
            "content-type": "application/json",
            "accept": "*/*",
            "x-version": clientVersion,
            "x-product": "autoclaw",
            "x-client-type": "pc",
            "x-harness-type": "zcode",
            "x-tm": "win",
            "x-lang": "zh-CN",
            "x-channel": "official",
            "x-auth-appid": authAppID,
            "x-auth-timestamp": ts,
            "x-auth-sign": sign,
            "x-trace-id": UUID().uuidString.lowercased(),
        ]
        if let token, !token.isEmpty {
            headers["authorization"] = "Bearer \(token)"
        }
        return headers
    }

    // MARK: - Session

    struct Credentials: Sendable {
        let accessToken: String
        let refreshToken: String
        let deviceID: String
        let expiresAt: Double?
        let userID: String?
    }

    enum FlowError: LocalizedError {
        case invalidResponse
        case badPhone
        case badCode
        case server(code: Int, message: String)
        case expired
        case missingToken

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "AutoClaw 返回了无法识别的响应。"
            case .badPhone: return "手机号格式不正确（需 11 位国内手机号）。"
            case .badCode: return "验证码格式不正确。"
            case .server(_, let message): return message
            case .expired: return "AutoClaw 登录态已过期，请重新登录。"
            case .missingToken: return "AutoClaw 登录未返回访问令牌。"
            }
        }
    }

    /// 上游登录错误码是人话翻译层：直接透传原文会把用户引向错误方向。
    private static let loginErrorMessages: [Int: String] = [
        400001: "请求参数有误，请检查手机号与验证码格式后重试。",
        630101: "获取验证码过于频繁，请稍后再试。",
        630202: "验证码不正确，请检查后重试。",
        631001: "授权码无效或已过期，请重新点击登录。",
        630014: "风控验证未通过，请重新点击登录再试一次。",
        631002: "本次登录缺少风控验证（验证码未通过或已过期），请重新点击登录再试一次。",
    ]

    /// 手机号归一：去空白/连字符、去 +86/86 前缀，必须是 11 位 1[2-9] 开头。
    static func normalizePhone(_ input: String) -> String? {
        var s = input.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        if s.hasPrefix("+86") { s = String(s.dropFirst(3)) }
        else if s.hasPrefix("86"), s.count == 13 { s = String(s.dropFirst(2)) }
        let pattern = "^1[2-9]\\d{9}$"
        return s.range(of: pattern, options: .regularExpression) != nil ? s : nil
    }

    /// `device_id`：32 字节随机 → 64 位小写十六进制。官方是公钥 SHA-256，
    /// 服务端只当不透明串；发码与登录必须是同一个值，刷新也要带。
    static func newDeviceID() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Login (国内：手机验证码两跳)

    static func sendCode(phone: String, root: String? = nil, session: URLSession = .shared) async throws -> String {
        guard let phone = normalizePhone(phone) else { throw FlowError.badPhone }
        let deviceID = newDeviceID()
        let payload = try await requestJSON(
            url: normalizeRoot(root) + sendCodePath,
            method: "POST",
            body: ["phone": phone, "source_id": "autoclaw", "device_id": deviceID],
            token: nil,
            session: session
        )
        // 成功判据是 code==0 **且** data.result===true：result 为假同样是失败。
        if let result = payload["result"] as? Bool, result == false {
            throw FlowError.server(code: 0, message: "验证码发送失败，请稍后重试。")
        }
        return deviceID
    }

    static func login(
        phone: String,
        code: String,
        deviceID: String,
        root: String? = nil,
        session: URLSession = .shared
    ) async throws -> Credentials {
        guard let phone = normalizePhone(phone) else { throw FlowError.badPhone }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // 必须是 JSON number —— 传字符串上游回 400001「请求数据有问题」。
        guard let numericCode = Int(trimmed), numericCode > 0 else { throw FlowError.badCode }
        let payload = try await requestJSON(
            url: normalizeRoot(root) + loginPath,
            method: "POST",
            body: [
                "phone": phone,
                "code": numericCode,
                "platform": "web",
                "source_id": "autoclaw",
                "device_id": deviceID,
            ],
            token: nil,
            session: session
        )
        guard let access = stripBearer(payload["access_token"] as? String), !access.isEmpty else {
            throw FlowError.missingToken
        }
        let refresh = stripBearer(payload["refresh_token"] as? String) ?? ""
        return Credentials(
            accessToken: access,
            refreshToken: refresh,
            deviceID: deviceID,
            expiresAt: JWT.expiry(access),
            userID: JWT.userID(access)
        )
    }

    // MARK: - Refresh

    /// 刷新 token。`refresh_token` 是轮换制：返回 nil 表示上游未换发，沿用旧值。
    static func refresh(
        refreshToken: String,
        deviceID: String?,
        root: String? = nil,
        session: URLSession = .shared
    ) async throws -> (accessToken: String, refreshToken: String?) {
        let root = normalizeRoot(root)
        var body: [String: Any] = ["refresh_token": stripBearer(refreshToken), "source_id": "autoclaw"]
        if let deviceID, !deviceID.isEmpty { body["device_id"] = deviceID }

        func call(_ path: String) async throws -> [String: Any] {
            try await requestJSON(url: root + path, method: "POST", body: body, token: nil, session: session)
        }

        var payload: [String: Any]
        do {
            payload = try await call(refreshPath)
        } catch FlowError.server(let code, _) where code == 400002 {
            // 签名校验失败 → 同头同 body 降级 agent-refresh 再试一次。
            payload = try await call(refreshFallbackPath)
        }
        guard let access = stripBearer(payload["access_token"] as? String), !access.isEmpty else {
            throw FlowError.missingToken
        }
        let rotated = stripBearer(payload["refresh_token"] as? String)
        return (access, (rotated?.isEmpty == false) ? rotated : nil)
    }

    // MARK: - Model catalog

    /// GET {root}/autoclaw-proxy/proxy/autoclaw-model-config，签名头 + 当前 token。
    /// 响应顶层直接是 `{models:[…]}`（无 code/data 信封）。
    static func fetchModels(
        accessToken: String,
        root: String? = nil,
        session: URLSession = .shared
    ) async throws -> [LLMModel] {
        let payload = try await requestJSON(
            url: normalizeRoot(root) + catalogPath,
            method: "GET",
            body: nil,
            token: accessToken,
            session: session
        )
        let raw = payload["models"] as? [[String: Any]] ?? []
        var models: [LLMModel] = []
        var seen = Set<String>()
        for entry in raw {
            guard let routeID = (entry["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !routeID.isEmpty, seen.insert(routeID).inserted else { continue }
            models.append(makeModel(routeID: routeID, entry: entry))
        }
        guard !models.isEmpty else {
            // 目录拉不到时退回静态兜底，至少让账号可用（与网关同口径）。
            return staticModels
        }
        return models
    }

    /// 目录拉不到时的兜底。`routeId` 无法从剥前缀的 id 反推（前缀决定计费通道），
    /// 所以这里必须显式写全。
    static let staticModels: [LLMModel] = [
        LLMModel(
            id: "zaicoding_glm-5.3",
            displayName: "GLM-5.3",
            provider: "AutoClaw",
            modalityOverride: .textOnly,
            contextWindow: 1_048_576,
            maxOutputTokens: 307_200
        ),
        LLMModel(
            id: "zai_glm-5.3-flash",
            displayName: "GLM-5.3-Flash",
            provider: "AutoClaw",
            modalityOverride: .vision,
            contextWindow: 1_048_576,
            maxOutputTokens: 131_072
        ),
    ]

    private static func makeModel(routeID: String, entry: [String: Any]) -> LLMModel {
        let input = entry["input"] as? [String] ?? []
        let images = input.contains("image")
        let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LLMModel(
            id: routeID,
            displayName: (name?.isEmpty == false ? name : nil) ?? stripRoutePrefix(routeID).uppercased(),
            provider: "AutoClaw",
            modalityOverride: images ? .vision : .textOnly,
            contextWindow: intValue(entry["contextWindow"]),
            maxOutputTokens: intValue(entry["maxTokens"]),
            // `reasoning: false` is an affirmative "this model does not reason";
            // true/nil stays permissive so the thinking engine keeps its default.
            supportsReasoning: (entry["reasoning"] as? Bool) == false ? false : nil
        )
    }

    // MARK: - Request-body gates

    /// 已知路由前缀。顺序有意义：先 `zaicoding_` 再 `zai_`，反过来会把
    /// `zaicoding_glm-5.3` 错剥成 `coding_glm-5.3`。
    static let routePrefixes = ["zaicoding_", "zai_"]

    /// body.model 必须是**剥掉路由前缀**的 id；`X-Request-Model` 头才是完整路由 id。
    static func stripRoutePrefix(_ model: String) -> String {
        for prefix in routePrefixes where model.hasPrefix(prefix) {
            return String(model.dropFirst(prefix.count))
        }
        return model
    }

    /// 出站 body 规范化（三处，其余字段透传）：
    /// `model` 剥前缀、system 首句补身份前缀、小 `max_tokens` 抬到 10000。
    /// 幂等：重复调用不会写两遍前缀。
    static func normalizeBody(_ body: [String: Any]) -> [String: Any] {
        var out = body
        if let model = out["model"] as? String {
            out["model"] = stripRoutePrefix(model)
        }
        if var messages = out["messages"] as? [[String: Any]] {
            if let first = messages.first,
               let role = first["role"] as? String, role == "system" || role == "developer" {
                messages[0] = prependIdentity(to: first)
            } else {
                messages.insert(["role": "system", "content": identityPrefix], at: 0)
            }
            out["messages"] = messages
        }
        if let raw = out["max_tokens"] {
            var value: Int?
            if let n = raw as? Int { value = n }
            else if let n = raw as? NSNumber { value = n.intValue }
            else if let d = raw as? Double { value = Int(d) }
            if let value, value > 0, value < maxTokensFloor {
                out["max_tokens"] = maxTokensFloor
            }
        }
        return out
    }

    private static func prependIdentity(to message: [String: Any]) -> [String: Any] {
        var msg = message
        if let text = msg["content"] as? String {
            // 幂等判据：首句已经是身份句就不动。
            if text.hasPrefix(identityLine) { return msg }
            msg["content"] = identityPrefix + "\n" + text
            return msg
        }
        if var parts = msg["content"] as? [[String: Any]] {
            if let idx = parts.firstIndex(where: { $0["text"] is String }) {
                if let text = parts[idx]["text"] as? String, text.hasPrefix(identityLine) { return msg }
                parts[idx]["text"] = identityPrefix + "\n" + ((parts[idx]["text"] as? String) ?? "")
            } else {
                parts.insert(["type": "text", "text": identityPrefix], at: 0)
            }
            msg["content"] = parts
            return msg
        }
        msg["content"] = identityPrefix
        return msg
    }

    // MARK: - Transport

    /// 一次 JSON 请求。上游信封是 `{code, msg|message, data}`；`code` 缺失视为成功
    /// （刷新响应就不带 code，`Number(undefined) != 0` 会把它误判成失败）。
    private static func requestJSON(
        url: String,
        method: String,
        body: [String: Any]?,
        token: String?,
        session: URLSession
    ) async throws -> [String: Any] {
        guard let requestURL = URL(string: url) else { throw FlowError.invalidResponse }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in signedHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if status == 401 { throw FlowError.expired }
            throw FlowError.invalidResponse
        }
        let code = (json["code"] as? NSNumber)?.intValue
            ?? (json["code"] as? String).flatMap(Int.init)
        if let code, code != 0 {
            if code == 401 || code == 410000 { throw FlowError.expired }
            let message = loginErrorMessages[code]
                ?? (json["msg"] as? String)
                ?? (json["message"] as? String)
                ?? "AutoClaw 请求失败（code \(code)）"
            throw FlowError.server(code: code, message: message)
        }
        if status == 401 { throw FlowError.expired }
        guard (200...299).contains(status) else {
            let message = (json["msg"] as? String) ?? (json["message"] as? String)
                ?? "AutoClaw 返回 HTTP \(status)"
            throw FlowError.server(code: status, message: message)
        }
        if let inner = json["data"] as? [String: Any] { return inner }
        return json
    }

    private static func stripBearer(_ value: String?) -> String? {
        guard let value else { return nil }
        var s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("bearer ") { s = String(s.dropFirst(7)) }
        return s
    }

    private static func intValue(_ value: Any?) -> Int? {
        let number: Double?
        if let n = value as? NSNumber { number = n.doubleValue }
        else if let s = value as? String { number = Double(s) }
        else { number = nil }
        guard let number, number > 0 else { return nil }
        return Int(number)
    }
}

// MARK: - JWT (payload only, never verified)

/// Reads claims out of a token for expiry/identity display only. The signature
/// is not checked — authority comes from the server that issued it.
enum AutoClawJWT {
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

/// Thin alias so the file's call sites read the same as the Raccoon provider's.
private enum JWT {
    static func expiry(_ token: String) -> Double? { AutoClawJWT.expiry(token) }
    static func userID(_ token: String) -> String? { AutoClawJWT.userID(token) }
}
