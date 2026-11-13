import Foundation
import CryptoKit
import Security

/// Trae (字节跳动 IDE) wire: chat, model directory, sign-in and renewal.
///
/// Protocol facts come from Apelin's `TraeWire` / `TraeOAuth` (PR #40), which
/// mapped them from client captures. Four of them are load-bearing and
/// invisible, so they are repeated here rather than left to the reader:
///
///   * the chat endpoint is `llm_utils_chat`, NOT `chat_sessions` — the latter
///     runs the model in Trae's own sandbox, which executes tools itself and
///     never hands a `tool_calls` back;
///   * one token goes in THREE headers (`Authorization: Cloud-IDE-JWT …`,
///     `X-Ide-Token`, `X-Cloudide-Token`);
///   * `body.model` and `body.config_name` must both name the model, and the
///     `function` field selects which roster may call it;
///   * every message's `content` is a text-block ARRAY, and a tool's
///     `parameters` is a JSON *string*, not an object.
enum TraeAPI {
    // MARK: - Builds

    enum Site: String, Sendable, CaseIterable {
        case china
        case international

        var displayName: String {
            switch self {
            case .china: return "Trae CN"
            case .international: return "Trae"
            }
        }

        /// Where chat and the model directory live.
        ///
        /// The international gateway is `coresg-normal.trae.ai`: the desktop
        /// client and TRAE SOLO both send `llm_utils_chat` and the SOLO
        /// directory there. `core-normal.trae.ai` is the account-service host
        /// and does not serve the roster the picker renders.
        var apiOrigin: String {
            switch self {
            case .china: return "https://trae-api-cn.mchost.guru"
            case .international: return "https://coresg-normal.trae.ai"
            }
        }

        /// Where the sign-in page is, when it is known without asking.
        var fixedLoginHost: String? {
            switch self {
            case .china: return "https://www.trae.cn"
            case .international: return nil
            }
        }

        var guidanceURLs: [String] {
            switch self {
            case .china: return []
            case .international:
                return [
                    "https://api.marscode.com/cloudide/api/v3/trae/GetLoginGuidance",
                    "https://api.trae.ai/cloudide/api/v3/trae/GetLoginGuidance",
                    "https://www.trae.ai/cloudide/api/v3/trae/GetLoginGuidance",
                ]
            }
        }

        var pluginVersion: String {
            self == .china ? "2.3.83560" : "local"
        }

        var appVersion: String {
            self == .china ? "3.3.100" : "3.5.54"
        }

        var deviceBrand: String { self == .china ? "" : "unknown" }
        var osInfo: String { self == .china ? "windows" : "unknown" }
        var osVersion: String { self == .china ? "Windows 10 Home" : "unknown" }
        var channelName: String? { self == .china ? "common" : nil }
        /// The international client sends a constant device id.
        var fixedDeviceID: String? { self == .china ? nil : "0" }
        /// The China client's machine id is 64 hex; the international one a UUID.
        var machineIsUUID: Bool { self == .international }

        /// Account gates its exchange may use, in order. Only one serves a
        /// given account's region.
        var exchangeOrigins: [String] {
            switch self {
            case .china:
                return ["https://api.trae.cn", "https://api.trae.com.cn"]
            case .international:
                return [
                    "https://grow-normal.trae.ai",
                    "https://growsg-normal.trae.ai",
                    "https://grow-normal.traeapi.us",
                    "https://api.marscode.com",
                    "https://api.trae.ai",
                    "https://www.trae.ai",
                ]
            }
        }
    }

    // MARK: - Paths

    static let chatPath = "/api/agent/v3/llm_utils_chat"
    static let directoryPath = "/api/ide/v1/get_detail_param"
    /// The sign-in exchange. Renewal uses a different path.
    static let authExchangePath = "/trae/api/v3/oauth/ExchangeToken"
    static let renewalPath = "/cloudide/api/v3/trae/oauth/ExchangeToken"

    static let appID = "6eefa01c-1036-4c7e-9ca5-d891f63bfcd8"
    static let clientID = "ono9krqynydwx5"

    /// The SOLO generation's build. The three version values are one set: a
    /// capture proved `x-ide-version-code`, `x-ide-version` and the User-Agent
    /// together are what the gate accepts, and changing one alone no longer
    /// matches its configuration table.
    static let ideVersion = "0.1.61"
    static let versionCode = 20260820

    /// The roster functions a model may be listed under, in the order the
    /// vendor's own picker resolves them.
    ///
    /// Trae splits its callable roster across SOLO modes and a model is only
    /// callable through the function that lists it (`glm-5.3` answers
    /// `4001 param is invalid` outside `solo_work_remote`). Asking two of them
    /// is what made the app show two DeepSeek rows while the official picker
    /// listed a dozen models, so every chat function the client uses is asked
    /// and the answers are unioned in this order.
    static let directoryFunctions = [
        "solo_work_remote", "solo_work_lite", "solo_agent_remote", "chat_v3", "solo_coder",
    ]
    /// Functions that can carry a chat model. A row listed only under a helper
    /// roster (`code_review_summary`, `fast_apply`, …) is not callable here.
    static let chatFunctions: Set<String> = Set(directoryFunctions)
    static let defaultFunction = "solo_work_remote"
    static let defaultModel = "auto"

    // MARK: - URLs

    static func chatURL(origin: String) -> URL? {
        URL(string: origin + chatPath)
    }

    static func directoryURL(origin: String) -> URL? {
        URL(string: origin + directoryPath)
    }

    /// The SOLO web directory the vendor's own model picker renders. Unlike
    /// `get_detail_param` (one roster per request, chat-function only) this
    /// answers every requested function in one document, which is where the
    /// models that were missing came from.
    static let remoteDirectoryPath = "/api/remote/v1/models"

    static func remoteDirectoryURL(origin: String, functions: [String]) -> URL? {
        let list = functions.joined(separator: ",")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ",+&=")
        guard let encoded = list.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: origin + remoteDirectoryPath + "?functions=" + encoded)
    }

    /// Where the SOLO web directory lives, given the chat origin.
    ///
    /// The directory is not always on the chat host: the China build serves
    /// chat from `trae-api-cn.mchost.guru` but the roster from `solo.trae.cn`.
    /// The international build serves both from `coresg-normal.trae.ai`. A
    /// custom base is assumed to mirror the directory under the same origin,
    /// which is the only thing a third-party endpoint could reasonably do.
    /// Directory hosts to try, in order. The international build has mirrored
    /// gateways (`coresg-normal` and `core-normal`) that serve the same roster;
    /// the China build splits chat (`mchost.guru`) from the roster
    /// (`solo.trae.cn`). Trying the mirror only when the first answer is
    /// unusable keeps one refresh cheap in the normal case.
    static func remoteOrigins(chatOrigin: String) -> [String] {
        let lower = chatOrigin.lowercased()
        if lower.contains("mchost.guru") || lower.contains("trae.cn") {
            return ["https://solo.trae.cn", "https://trae-api-cn.mchost.guru"]
        }
        if lower.contains("trae.ai") {
            return ["https://coresg-normal.trae.ai", "https://core-normal.trae.ai"]
        }
        return [chatOrigin]
    }

    /// The SOLO web portal's own dressing differs by build; both are accepted
    /// by the gateways, so each keeps the shape its own portal sends.
    ///
    /// The backend validates `Origin`/`Referer` against the session's real
    /// origin, so a stale value answers 401 even with a fresh token.
    static func remoteDressing(chatOrigin: String) -> (referer: String, timezone: String, language: String) {
        let lower = chatOrigin.lowercased()
        let china = lower.contains("mchost.guru") || lower.contains("trae.cn")
        return china
            ? ("https://solo.trae.cn/", "Asia/Shanghai", "zh-cn")
            : ("https://work.trae.ai/", "Asia/Singapore", "en")
    }

    // MARK: - Headers

    /// The identity headers every Trae request carries.
    static func clientHeaders() -> [String: String] {
        [
            "x-plugin-channel": "icube-ai",
            "x-app-id": appID,
            "x-device-type": "ios",
            "x-device-cpu": "arm64",
            "x-ide-version-type": "stable",
            "x-app-version": ideVersion,
            "x-ide-version": ideVersion,
            "x-app-version-code": String(versionCode),
            "x-ide-version-code": String(versionCode),
            "request-traffic-type": "prod",
            "User-Agent": "Trae/\(ideVersion)",
            "Accept": "application/json",
        ]
    }

    /// The token in the three places the gate reads it, plus the machine and
    /// device ids. A pasted token made neither, so both are derived from the
    /// account — there is no Trae install here to read them from.
    static func accountHeaders(
        token: String,
        userID: String?,
        machineID: String?,
        deviceID: String?
    ) -> [String: String] {
        let trace = traceID()
        let machine = machineID ?? derivedMachineID(userID?.isEmpty == false ? userID! : token)
        var headers = [
            "Authorization": "Cloud-IDE-JWT \(token)",
            "X-Ide-Token": token,
            "X-Cloudide-Token": token,
            "x-machine-id": machine,
            "x-device-id": deviceID ?? machine,
            "x-custom-trace-id": trace,
            "x-flow-traceparent": "04-\(trace)-\(trace.prefix(16))-01",
        ]
        if let userID, !userID.isEmpty { headers["x-uid"] = userID }
        return headers
    }

    static func traceID() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<32).map { _ in "0123456789abcdef".randomElement(using: &generator) ?? "0" })
    }

    /// 32 hex digits, the same for one account across requests and renewals.
    static func derivedMachineID(_ account: String) -> String {
        let digest = SHA256.hash(data: Data(account.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    // MARK: - Request body

    /// A request body as `llm_utils_chat` takes it.
    ///
    /// The OpenAI body is kept for its messages, tools and reasoning effort;
    /// everything else is this wire's own. Every transform below exists because
    /// the upstream validator rejects the un-mended form.
    static func mendedBody(_ root: [String: Any], model: String, function: String = defaultFunction) -> [String: Any] {
        var body: [String: Any] = [
            "app_id": appID,
            "app_version_code": versionCode,
            "function": function,
            "model": model,
            "config_name": model,
            "stream": true,
            "messages": mendedMessages(root["messages"] as? [[String: Any]] ?? []),
        ]
        if let tools = root["tools"] as? [[String: Any]], !tools.isEmpty {
            body["tools"] = mendedTools(tools)
        }
        if let effort = root["reasoning_effort"] as? String, !effort.isEmpty {
            body["reasoning_effort"] = effort
        }
        if body["messages"] as? [[String: Any]] == nil {
            body["messages"] = [["role": "user", "content": [["type": "text", "text": ""]]]]
        }
        return body
    }

    /// `developer` becomes `system`; an interrupted assistant turn's null or
    /// empty content becomes an empty block (the validator accepts that where
    /// it refuses null, once, then poisons every later request); a turn with
    /// neither text nor calls goes; `tool_calls` is read back as
    /// `function_call`.
    static func mendedMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for var message in messages {
            if (message["role"] as? String) == "developer" { message["role"] = "system" }
            let role = message["role"] as? String ?? "user"
            let calls = message["tool_calls"] as? [[String: Any]]
            let hasContent: Bool = {
                if let text = message["content"] as? String { return !text.isEmpty }
                if let blocks = message["content"] as? [[String: Any]] { return !blocks.isEmpty }
                return false
            }()
            if role == "assistant", !hasContent, (calls ?? []).isEmpty { continue }
            message["content"] = textBlocks(message["content"])
            message.removeValue(forKey: "reasoning_content")
            message.removeValue(forKey: "reasoning_details")
            if role == "assistant", let calls, !calls.isEmpty {
                message["function_call"] = calls
                message.removeValue(forKey: "tool_calls")
            }
            out.append(message)
        }
        return out
    }

    /// Content as `[{type: "text", text: …}]`. This wire takes text only, so
    /// image blocks are dropped rather than sent in a shape it rejects.
    static func textBlocks(_ content: Any?) -> [[String: Any]] {
        switch content {
        case let text as String:
            return [["type": "text", "text": text]]
        case let blocks as [[String: Any]]:
            let texts = blocks.compactMap { block -> [String: Any]? in
                guard (block["type"] as? String) == "text",
                      let text = block["text"] as? String else { return nil }
                return ["type": "text", "text": text]
            }
            return texts.isEmpty ? [["type": "text", "text": ""]] : texts
        default:
            return [["type": "text", "text": ""]]
        }
    }

    /// `parameters` is a JSON *string* on this wire, not an object.
    static func mendedTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool in
            guard var function = tool["function"] as? [String: Any] else { return nil }
            if let parameters = function["parameters"], !(parameters is NSNull),
               let data = try? JSONSerialization.data(withJSONObject: parameters),
               let text = String(data: data, encoding: .utf8) {
                function["parameters"] = text
            } else {
                function["parameters"] = #"{"type":"object","properties":{}}"#
            }
            return ["type": "function", "function": function]
        }
    }

    // MARK: - Model directory

    /// One model as the directory publishes it.
    struct Entry: Sendable, Hashable {
        var id: String
        var displayName: String
        var function: String
        var reasoning: Bool
        var contextWindow: Int
        var maxTokens: Int
    }

    /// `POST {origin}/api/ide/v1/get_detail_param` for one roster function.
    static func directoryRequest(origin: String, function: String, headers: [String: String]) -> URLRequest? {
        guard let url = directoryURL(origin: origin) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        for (name, value) in headers where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "function": function,
            "config_names": NSNull(),
            "need_prompt": false,
            "current_config_info": NSNull(),
            "poly_prompt": true,
            "mode_type": NSNull(),
            "agent_type": NSNull(),
        ], options: [.sortedKeys])
        return request
    }

    /// Every entry of one roster, minus the ones the IDE never shows a user.
    static func entries(in document: [String: Any], function: String = defaultFunction) -> [Entry] {
        let list = document["config_info_list"] as? [[String: Any]] ?? []
        return list.compactMap { raw in
            guard let id = raw["config_name"] as? String, !id.isEmpty, !isHidden(id),
                  raw["is_invisible_to_user"] as? Bool != true else { return nil }
            let display = raw["display_config"] as? [String: Any] ?? [:]
            let context = raw["context_window_tokens"] as? [String: Any] ?? [:]
            let detail = (raw["model_detail_list"] as? [[String: Any]])?.first ?? [:]
            let window = (context["dev"] as? NSNumber)?.intValue
                ?? (detail["prompt_max_tokens"] as? NSNumber)?.intValue ?? 0
            let maxTokens = (detail["max_tokens"] as? NSNumber)?.intValue ?? 0
            return Entry(
                id: id,
                displayName: (display["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                function: function,
                reasoning: (display["model_capability"] as? String) == "reasoning_model",
                contextWindow: window > 0 ? window : 200_000,
                maxTokens: maxTokens > 0 ? maxTokens : 64_000
            )
        }
    }

    /// The directory lists the agent's own internal entries beside the models a
    /// user may pick. No user-facing id carries `agent`, and the summarisers and
    /// sub-agents are not callable as models.
    static func isHidden(_ id: String) -> Bool {
        if id.hasPrefix("custom_model_") || id.hasPrefix("search_agent") { return true }
        if id.contains("agent") { return true }
        if id.contains("_advisor") || id.hasSuffix("_auto") { return true }
        for prefix in ["summary", "title_generation", "input_optimization", "fast_apply"]
        where id.hasPrefix(prefix) {
            return true
        }
        return id == "sagitta" || id == "aquila"
    }

    /// The live roster: the SOLO web directory first (one document, every chat
    /// function), then `get_detail_param` for anything it did not list.
    ///
    /// The web directory is what the vendor's own picker renders, so it is the
    /// authoritative "what can this account choose" answer; `get_detail_param`
    /// supplies the per-function metadata (`max_tokens`, capability flags) the
    /// directory does not publish. A failure costs only that source, never the
    /// whole list.
    static func roster(origin: String, headers: [String: String], session: URLSession = .shared) async -> [Entry] {
        async let remote = remoteRoster(origin: origin, headers: headers, session: session)
        async let detail = detailRoster(origin: origin, headers: headers, session: session)
        let (fromRemote, fromDetail) = await (remote, detail)
        if fromRemote.isEmpty { return fromDetail }
        // Directory order wins; detail metadata refines a row it also lists.
        var byID = Dictionary(fromDetail.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var out: [Entry] = []
        for entry in fromRemote where seen.insert(entry.id).inserted {
            if let detail = byID.removeValue(forKey: entry.id) {
                var merged = entry
                merged.maxTokens = detail.maxTokens
                merged.reasoning = entry.reasoning || detail.reasoning
                out.append(merged)
            } else {
                out.append(entry)
            }
        }
        // Rows only `get_detail_param` knows stay callable rather than vanish.
        for entry in fromDetail where seen.insert(entry.id).inserted { out.append(entry) }
        return out
    }

    /// `GET {origin}/api/remote/v1/models?functions=…`, grouped by function.
    static func remoteDirectoryRequest(origin: String, headers: [String: String]) -> URLRequest? {
        guard let url = remoteDirectoryURL(origin: origin, functions: directoryFunctions) else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        for (name, value) in headers where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // The SOLO web portal's own dressing: the gateway accepts the plugin
        // identity too, but these are what the picker request carries.
        let dressing = remoteDressing(chatOrigin: origin)
        request.setValue("web", forHTTPHeaderField: "x-trae-client-type")
        request.setValue(dressing.timezone, forHTTPHeaderField: "x-trae-user-timezone")
        request.setValue(dressing.language, forHTTPHeaderField: "x-preferenced-language")
        request.setValue(dressing.referer, forHTTPHeaderField: "Referer")
        request.setValue(dressing.referer, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Parse `data.list[] → { function, models[] }`, preserving the declared
    /// chat-function priority and keeping models the picker can actually offer.
    static func remoteEntries(in document: [String: Any]) -> [Entry] {
        let data = document["data"] as? [String: Any] ?? document
        let groups = data["list"] as? [[String: Any]] ?? []
        // A function can be sent more than once; bucket instead of overwriting.
        var byFunction: [String: [[String: Any]]] = [:]
        for group in groups {
            let name = group["function"] as? String ?? ""
            byFunction[name, default: []].append(group)
        }
        var seen = Set<String>()
        var out: [Entry] = []
        func append(_ function: String?, _ models: [[String: Any]]) {
            let attributed = function.flatMap { chatFunctions.contains($0) ? $0 : nil }
            for raw in models {
                guard let id = raw["name"] as? String, !id.isEmpty, !isHidden(id) else { continue }
                guard seen.insert(id).inserted else { continue }
                let display = (raw["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
                let context = raw["context_window_tokens"] as? [String: Any] ?? [:]
                let window = (context["dev"] as? NSNumber)?.intValue ?? 0
                let features = raw["features"] as? [String: Any] ?? [:]
                let reasoning = (features["reasoning"] as? [String: Any])?["enable"] as? Bool == true
                out.append(Entry(
                    id: id,
                    displayName: display,
                    function: attributed ?? defaultFunction,
                    reasoning: reasoning,
                    contextWindow: window > 0 ? window : 200_000,
                    maxTokens: 64_000
                ))
            }
        }
        for function in directoryFunctions {
            for group in byFunction[function] ?? [] {
                append(function, group["models"] as? [[String: Any]] ?? [])
            }
        }
        // A model listed only under a helper roster (`code_review_summary`,
        // `fast_apply`, …) is not a chat model: `llm_utils_chat` would answer
        // 4001. Leaving it out is what keeps every listed row callable.
        return out
    }

    static func remoteRoster(origin: String, headers: [String: String], session: URLSession) async -> [Entry] {
        // Mirror gateways serve the same roster; use the first usable answer.
        for directoryOrigin in remoteOrigins(chatOrigin: origin) {
            guard let request = remoteDirectoryRequest(origin: directoryOrigin, headers: headers),
                  let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            let entries = remoteEntries(in: document)
            if !entries.isEmpty { return entries }
        }
        return []
    }

    /// The per-function `get_detail_param` roster, asked concurrently. A failure
    /// costs only its own models.
    static func detailRoster(origin: String, headers: [String: String], session: URLSession) async -> [Entry] {
        await withTaskGroup(of: (Int, [Entry]).self) { group in
            for (index, function) in directoryFunctions.enumerated() {
                guard let request = directoryRequest(origin: origin, function: function, headers: headers) else {
                    continue
                }
                group.addTask {
                    guard let (data, response) = try? await session.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                        return (index, [])
                    }
                    return (index, entries(in: document, function: function))
                }
            }
            var listings: [Int: [Entry]] = [:]
            for await (index, listed) in group { listings[index] = listed }
            var seen = Set<String>()
            var out: [Entry] = []
            // Preserve the declared priority, independent of network completion order.
            for index in directoryFunctions.indices {
                for entry in listings[index] ?? [] where seen.insert(entry.id).inserted { out.append(entry) }
            }
            return out
        }
    }

    /// Request-local provider cache. The identity includes the origin and token
    /// digest, so another account or endpoint cannot reuse a model's route.
    final class ModelFunctions: @unchecked Sendable {
        private let lock = NSLock()
        private var identity = ""
        private var functions: [String: String] = [:]

        func needsDirectory(identity: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return self.identity != identity || functions.isEmpty
        }

        func store(_ entries: [Entry], identity: String) {
            lock.lock(); defer { lock.unlock() }
            self.identity = identity
            functions = Dictionary(entries.map { ($0.id, $0.function) }, uniquingKeysWith: { first, _ in first })
        }

        func function(for model: String) -> String {
            lock.lock(); defer { lock.unlock() }
            return functions[model] ?? TraeAPI.defaultFunction
        }
    }

    // MARK: - Helpers

    static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = object[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    static func stripBearer(_ value: String?) -> String? {
        guard let value else { return nil }
        var s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("bearer ") { s = String(s.dropFirst(7)) }
        return s
    }
}
