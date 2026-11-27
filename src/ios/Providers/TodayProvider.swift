import Foundation

/// Today returns a completed reply, not first-token deltas. A fresh request can
/// spend 30s each on token exchange, selection and send, then poll for 120s;
/// allow one last 30s poll HTTP request. Other providers keep their own budgets.
enum TodayCompletionPolicy {
    static let requestTimeout: TimeInterval = 30
    static let pollingTimeout: TimeInterval = 120
    static let latencyProbeTimeout = pollingTimeout + 4 * requestTimeout
}

/// Today AI (todayai.cn) native provider.
///
/// Today is not an OpenAI-compatible endpoint.  The web service exchanges the
/// browser session cookie for a short-lived API JWT, accepts canonical-v1
/// messages, and exposes completed replies through a polling endpoint.  This
/// adapter intentionally keeps that protocol private to this provider instead
/// of pretending that `/api/cloud` is `/v1/chat/completions`.
final class TodayProvider: LLMProvider {
    let name = "Today AI"
    var model: LLMModel

    private let client: TodayClient

    init(sessionCookie: String, model: LLMModel) {
        self.model = model
        self.client = TodayClient(sessionCookie: sessionCookie)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        let text = try await client.complete(
            messages: messages,
            systemPrompt: systemPrompt,
            modelID: model.id
        )
        return LLMResponse(text: text, stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        try Task.checkCancellation()
        let selectedModel = model.id
        let client = self.client
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    continuation.yield(.started)
                    let text = try await client.complete(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        modelID: selectedModel
                    )
                    try Task.checkCancellation()
                    if !text.isEmpty { continuation.yield(.text(text)) }
                    continuation.yield(.finished(stopReason: "stop"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Once POST /messages has been attempted, an error (even a polling 429 or
    /// timeout) is not permission to submit a second billable generation.
    static func generationMayHaveBeenSubmitted(_ error: Error) -> Bool {
        if case TodayProviderError.generationSubmitted = error { return true }
        return false
    }

    static func isCompletionTimeout(_ error: Error) -> Bool {
        if case TodayProviderError.timeout = error { return true }
        if case TodayProviderError.generationSubmitted(let underlying) = error {
            return isCompletionTimeout(underlying)
        }
        return (error as? URLError)?.code == .timedOut
    }

    /// Account-scoped model discovery used by ProviderConfigStore.
    static func fetchModels(sessionCookie: String) async throws -> [LLMModel] {
        let client = TodayClient(sessionCookie: sessionCookie)
        return try await client.fetchModels()
    }
}

private enum TodayProviderError: LocalizedError {
    case missingCookie
    case invalidResponse(String)
    case http(Int, String)
    case emptyReply
    case timeout
    case generationSubmitted(Error)

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            return "Today AI session cookie is missing."
        case .invalidResponse(let detail):
            return "Today AI returned an invalid response: \(detail)"
        case .http(let status, let detail):
            return "Today AI request failed (HTTP \(status)): \(detail)"
        case .emptyReply:
            return "Today AI returned an empty reply."
        case .timeout:
            return "Today AI did not finish the request in time."
        case .generationSubmitted(let underlying):
            return underlying.localizedDescription
        }
    }
}

/// Covers ALL Today clients (Quick Test/chat/probes), not just one batch. The
/// normalized cookie is an in-memory key only: never logged or persisted here.
/// Cancellation stops local waiting; it cannot promise to stop remote billing.
private actor TodayAccountGate {
    static let shared = TodayAccountGate()
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var held: Set<String> = []
    private var waiting: [String: [Waiter]] = [:]

    func acquire(_ account: String) async throws {
        try Task.checkCancellation()
        if held.insert(account).inserted { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiting[account, default: []].append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(account, id: id) }
        }
        // The caller owns the permit after resume, even if just cancelled;
        // it must release it in its cancellation/error path.
    }

    private func cancel(_ account: String, id: UUID) {
        guard let index = waiting[account]?.firstIndex(where: { $0.id == id }),
              let waiter = waiting[account]?.remove(at: index) else { return }
        if waiting[account]?.isEmpty == true { waiting.removeValue(forKey: account) }
        waiter.continuation.resume(throwing: CancellationError())
    }

    func release(_ account: String) {
        if let waiter = waiting[account]?.first {
            waiting[account]?.removeFirst()
            if waiting[account]?.isEmpty == true { waiting.removeValue(forKey: account) }
            waiter.continuation.resume()
        } else {
            held.remove(account)
        }
    }
}

private actor TodayClient {
    private let sessionCookie: String
    private var accessToken = ""
    private var tokenExpiresAt = Date.distantPast
    // Do not retain a server-side main thread as local conversation history.

    init(sessionCookie: String) {
        self.sessionCookie = Self.normalizeCookie(sessionCookie)
    }

    func fetchModels() async throws -> [LLMModel] {
        let status: TodayPricingStatus = try await requestJSON(
            method: "GET", path: "/v1/pricing/status"
        )
        let options = status.data.status.modelOptions?.options ?? []
        return options.compactMap { option -> LLMModel? in
            guard !option.disabled else { return nil }
            let id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let title = option.display?.title ?? option.title ?? modelDisplayName(from: id)
            return LLMModel(
                id: id,
                displayName: title,
                provider: ProviderType.today.displayName,
                modalityOverride: .textOnly,
                contextWindow: 128_000,
                maxOutputTokens: 16_384,
                supportsReasoning: false
            )
        }
    }

    func complete(messages: [LLMMessage], systemPrompt: String?, modelID: String) async throws -> String {
        try Task.checkCancellation()
        guard !sessionCookie.isEmpty else { throw TodayProviderError.missingCookie }
        let userText = messages.last(where: { $0.role == .user })?.content ?? ""
        guard !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TodayProviderError.invalidResponse("no user message")
        }

        // Rebuild from the caller's history on EVERY turn, including after
        // provider recreation. Never import account-wide main-chat history.
        // This scopes our supplied context; main-chat server memory is not an
        // isolated/stateless API and cannot provide a hard privacy boundary.
        let text = TodaySendRequest.context(messages: messages, systemPrompt: systemPrompt)
        guard text.count <= 1_000_000 else {
            throw TodayProviderError.invalidResponse("conversation context exceeds Today text limit")
        }
        try await TodayAccountGate.shared.acquire(sessionCookie)
        var submitted = false
        do {
            try Task.checkCancellation()
            try await selectModel(modelID)
            try Task.checkCancellation()
            let clientMessageID = UUID().uuidString
            // Set BEFORE the await: a lost POST response may still be billable.
            submitted = true
            let sent: TodaySendResponse = try await requestJSON(
                method: "POST",
                path: "/v1/messages",
                body: TodaySendRequest(text: text, clientMessageID: clientMessageID)
            )
            try Task.checkCancellation()
            if let echoedID = sent.clientMessageID, echoedID != clientMessageID {
                throw TodayProviderError.invalidResponse("messages response clientMessageId mismatch")
            }
            let reply = try await pollReply(clientMessageID: clientMessageID, conversationID: sent.conversationID)
            await TodayAccountGate.shared.release(sessionCookie)
            return reply
        } catch {
            await TodayAccountGate.shared.release(sessionCookie)
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if submitted { throw TodayProviderError.generationSubmitted(error) }
            throw error
        }
    }

    private func selectModel(_ modelID: String) async throws {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw TodayProviderError.invalidResponse("no model option") }
        // Old saved bare model IDs remain usable; mode/custom/model IDs must
        // round-trip verbatim. Selection is account-global, so never cache it.
        let optionID = ["mode.", "custom.", "model."].contains(where: { id.hasPrefix($0) }) ? id : "model.\(id)"
        try await requestJSONVoid(
            method: "PUT",
            path: "/v1/pricing/model-option",
            body: TodayModelOption(optionId: optionID)
        )
    }

    private func pollReply(clientMessageID: String, conversationID: String?) async throws -> String {
        let deadline = Date().addingTimeInterval(TodayCompletionPolicy.pollingTimeout)
        var interval: UInt64 = 250_000_000
        while Date() < deadline {
            try Task.checkCancellation()
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "limit", value: "100")]
            if let conversationID, !conversationID.isEmpty, conversationID != "main" {
                components.queryItems?.append(URLQueryItem(name: "conversationId", value: conversationID))
            } else {
                components.queryItems?.append(URLQueryItem(name: "isMainChat", value: "true"))
            }
            let response: TodayConversationResponse = try await requestJSON(
                method: "GET", path: "/v1/conversations/messages?" + (components.percentEncodedQuery ?? "")
            )
            let matches = response.data.items.filter {
                $0.role == "assistant" && $0.belongs(to: clientMessageID)
            }
            // Never fall back to an unrelated assistant in the shared main chat.
            if let item = matches.first(where: { $0.state == "interrupted" }) {
                _ = item
                throw TodayProviderError.invalidResponse("generation interrupted")
            }
            if let item = matches.first(where: { $0.state == "completed" || ($0.isFinal && $0.state != "in_progress") }) {
                let text = item.body.parts.filter { $0.messageType == "text" }.compactMap { $0.content?.text }.joined()
                guard !text.isEmpty else { throw TodayProviderError.emptyReply }
                return text
            }
            try await Task.sleep(nanoseconds: interval)
            interval = min(interval + 100_000_000, 1_000_000_000)
        }
        // Partial text is not a successful final response.
        throw TodayProviderError.timeout
    }

    private struct EmptyBody: Encodable {}

    private func requestJSON<T: Decodable>(method: String, path: String) async throws -> T {
        try await requestJSON(method: method, path: path, body: Optional<EmptyBody>.none)
    }

    private func requestJSON<T: Decodable, Body: Encodable>(
        method: String, path: String, body: Body?
    ) async throws -> T {
        let data = try await request(method: method, path: path, body: body)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw TodayProviderError.invalidResponse(error.localizedDescription) }
    }

    private func requestJSONVoid<Body: Encodable>(
        method: String, path: String, body: Body?
    ) async throws {
        _ = try await request(method: method, path: path, body: body)
    }

    private func request<Body: Encodable>(method: String, path: String, body: Body?) async throws -> Data {
        try Task.checkCancellation()
        let token = try await validToken()
        try Task.checkCancellation()
        var request = URLRequest(url: Self.apiURL(path: path))
        request.httpMethod = method
        request.timeoutInterval = TodayCompletionPolicy.requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(TodayAPI.appBase, forHTTPHeaderField: "Origin")
        request.setValue(TodayAPI.appBase + "/", forHTTPHeaderField: "Referer")
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TodayProviderError.invalidResponse("not an HTTP response")
        }
        if http.statusCode == 401 {
            accessToken = ""
            tokenExpiresAt = .distantPast
            // Refresh/retry reads and idempotent selection only. Never replay
            // a generation POST, whose delivery/billing may be uncertain.
            guard !(method == "POST" && path == "/v1/messages") else {
                throw TodayProviderError.http(http.statusCode, Self.snippet(data))
            }
            let retryToken = try await validToken()
            try Task.checkCancellation()
            request.setValue("Bearer \(retryToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
            guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                throw TodayProviderError.invalidResponse("not an HTTP response")
            }
            guard (200..<300).contains(retryHTTP.statusCode) else {
                throw TodayProviderError.http(retryHTTP.statusCode, Self.snippet(retryData))
            }
            return retryData
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TodayProviderError.http(http.statusCode, Self.snippet(data))
        }
        return data
    }

    private func validToken() async throws -> String {
        if !accessToken.isEmpty, Date() < tokenExpiresAt.addingTimeInterval(-60) {
            return accessToken
        }
        guard !sessionCookie.isEmpty else { throw TodayProviderError.missingCookie }
        var request = URLRequest(url: URL(string: TodayAPI.appBase + "/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = TodayCompletionPolicy.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue(TodayAPI.appBase, forHTTPHeaderField: "Origin")
        request.setValue(TodayAPI.appBase + "/", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONEncoder().encode(TodayTokenRequest(
            audience: TodayAPI.audience, expiresIn: 3600
        ))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TodayProviderError.invalidResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TodayProviderError.http(http.statusCode, Self.snippet(data))
        }
        let token: TodayTokenResponse
        do { token = try JSONDecoder().decode(TodayTokenResponse.self, from: data) }
        catch { throw TodayProviderError.invalidResponse(error.localizedDescription) }
        guard !token.token.isEmpty else { throw TodayProviderError.invalidResponse("token is empty") }
        accessToken = token.token
        tokenExpiresAt = token.expiration
        return token.token
    }

    private static func normalizeCookie(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\r"), !trimmed.contains("\n") else { return "" }
        let stripped = trimmed.lowercased().hasPrefix("cookie:")
            ? String(trimmed.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces)
            : trimmed
        if let pair = stripped.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("__Secure-better-auth.session_token=") }) {
            return pair
        }
        // A bare token may contain Base64 '=' padding. Reject other cookies,
        // newlines and headers instead of forwarding them to the service.
        guard !stripped.isEmpty, !stripped.contains(";"),
              !stripped.contains("\r"), !stripped.contains("\n"),
              stripped.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return "" }
        return "__Secure-better-auth.session_token=\(stripped)"
    }

    private static func apiURL(path: String) -> URL {
        URL(string: TodayAPI.appBase + "/api/cloud" + path)!
    }

    private static func snippet(_ data: Data) -> String {
        // Do not surface server response bodies: they may echo credentials.
        return "See Today AI account status or sign in again."
    }
}

private enum TodayAPI {
    static let appBase = "https://todayai.cn"
    static let audience = "https://api.todayai.cn"
}

private struct TodayTokenRequest: Encodable {
    let audience: String
    let expiresIn: Int
}

private struct TodayTokenResponse: Decodable {
    let token: String
    let expiresIn: Int?
    let expiresAt: Double?
    enum Keys: String, CodingKey { case token, expiresIn, expiresAt, data }
    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Keys.self)
        let c = (try? root.nestedContainer(keyedBy: Keys.self, forKey: .data)) ?? root
        token = try c.decode(String.self, forKey: .token)
        expiresIn = try c.decodeIfPresent(Int.self, forKey: .expiresIn)
        if let number = try? c.decode(Double.self, forKey: .expiresAt) {
            expiresAt = number > 10_000_000_000 ? number / 1000 : number
        } else if let string = try? c.decode(String.self, forKey: .expiresAt) {
            expiresAt = ISO8601DateFormatter().date(from: string)?.timeIntervalSince1970
        } else { expiresAt = nil }
    }
    var expiration: Date {
        var candidates: [Double] = []
        if let expiresAt { candidates.append(expiresAt) }
        if let expiresIn { candidates.append(Date().timeIntervalSince1970 + Double(expiresIn)) }
        let parts = token.split(separator: ".")
        if parts.count == 3 {
            var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            text += String(repeating: "=", count: (4 - text.count % 4) % 4)
            if let data = Data(base64Encoded: text),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let exp = object["exp"] as? Double { candidates.append(exp) }
        }
        return Date(timeIntervalSince1970: candidates.min() ?? Date().addingTimeInterval(300).timeIntervalSince1970)
    }
}

private struct TodayModelOption: Encodable {
    let optionId: String
}

private struct TodaySendRequest: Encodable {
    struct Body: Encodable {
        struct Part: Encodable { let id: String; let type: String; let text: String }
        let parts: [Part]
    }
    let body: Body
    let clientMessageId: String
    let isMainChat = true

    init(text: String, clientMessageID: String) {
        body = Body(parts: [.init(id: UUID().uuidString, type: "text", text: text)])
        clientMessageId = clientMessageID
    }

    static func context(messages: [LLMMessage], systemPrompt: String?) -> String {
        var sections: [String] = []
        if let systemPrompt, !systemPrompt.isEmpty { sections.append("[system]\n" + systemPrompt) }
        for message in messages where !message.content.isEmpty {
            sections.append("[\(message.role)]\n" + message.content)
        }
        return sections.joined(separator: "\n\n")
    }
}

private struct TodaySendResponse: Decodable {
    let clientMessageID: String?
    let conversationID: String?
    enum Keys: String, CodingKey { case clientMessageId, conversationId, canonicalMessage, data }
    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Keys.self)
        let payload = (try? root.nestedContainer(keyedBy: Keys.self, forKey: .data)) ?? root
        let canonical = try? payload.nestedContainer(keyedBy: Keys.self, forKey: .canonicalMessage)
        clientMessageID = try payload.decodeIfPresent(String.self, forKey: .clientMessageId)
            ?? canonical?.decodeIfPresent(String.self, forKey: .clientMessageId)
        conversationID = try payload.decodeIfPresent(String.self, forKey: .conversationId)
            ?? canonical?.decodeIfPresent(String.self, forKey: .conversationId)
    }
}

private struct TodayPricingStatus: Decodable {
    let data: Payload
    struct Payload: Decodable { let status: Status }
    struct Status: Decodable { let modelOptions: Options? }
    struct Options: Decodable { let options: [Option]? }
    struct Option: Decodable {
        let id: String
        let disabled: Bool
        let title: String?
        let display: Display?
        struct Display: Decodable { let title: String? }
        enum CodingKeys: String, CodingKey { case id, disabled, title, display }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
            title = try c.decodeIfPresent(String.self, forKey: .title)
            display = try c.decodeIfPresent(Display.self, forKey: .display)
        }
    }
}

private struct TodayConversationResponse: Decodable {
    let data: Payload
    struct Payload: Decodable { let items: [Item] }
    struct Item: Decodable {
        let role: String
        let state: String
        let isFinal: Bool
        let body: Body
        let originClientMessageId: String?
        let originClientMessageIds: [String]?
        let clientMessageId: String?
        func belongs(to id: String) -> Bool {
            originClientMessageId == id || (originClientMessageIds?.contains(id) ?? false) || clientMessageId == id
        }
        struct Body: Decodable { let parts: [Part] }
        struct Part: Decodable {
            let messageType: String
            let content: Content?
            enum Keys: String, CodingKey { case messageType, content }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                messageType = (try? c.decode(String.self, forKey: .messageType)) ?? ""
                content = try? c.decode(Content.self, forKey: .content)
            }
            struct Content: Decodable {
                let text: String?
                enum Keys: String, CodingKey { case text }
                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: Keys.self)
                    // 'turn' text arrays and unknown part types must not make
                    // an entire history page fail; only text parts are output.
                    text = try? c.decode(String.self, forKey: .text)
                }
            }
        }
        enum CodingKeys: String, CodingKey {
            case role, state, isFinal, body, originClientMessageId, originClientMessageIds, clientMessageId
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
            state = (try c.decodeIfPresent(String.self, forKey: .state) ?? "").lowercased()
            isFinal = try c.decodeIfPresent(Bool.self, forKey: .isFinal) ?? false
            body = try c.decodeIfPresent(Body.self, forKey: .body) ?? Body(parts: [])
            originClientMessageId = try c.decodeIfPresent(String.self, forKey: .originClientMessageId)
            originClientMessageIds = try c.decodeIfPresent([String].self, forKey: .originClientMessageIds)
            clientMessageId = try c.decodeIfPresent(String.self, forKey: .clientMessageId)
        }
    }
}
