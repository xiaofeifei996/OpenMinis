import Foundation

/// Translates Trae's SSE dialect into OpenAI `chat.completion.chunk` frames.
///
/// Trae answers `event: output` with `{response, reasoning_content, tool_calls}`,
/// `event: token_usage`, `event: error {code, message}` and `event: done
/// {finish_reason}` — no `choices` anywhere, so nothing downstream would read it
/// as it comes. Rather than teach the provider a second dialect, it hands each
/// frame here and parses the result through the one path it already has.
///
/// Frame names and their meanings come from Apelin's `TraeWire` (PR #40), where
/// this wire was first mapped from client captures.
protocol TraeStreamTranslator: Sendable {
    // Marker only. Mutable frame/tool state belongs to one request, never to
    // the provider instance (which can serve concurrent requests).
}

/// The concrete Trae dialect.
struct TraeDialect: TraeStreamTranslator {
    func translate(event: String, payload: String) -> [String] {
        Self.translate(event: event, payload: payload)
    }

    static func translate(event: String, payload: String) -> [String] {
        // A frame with no event name is the gateway's default (`output`);
        // `message` is what some SSE readers report for a nameless frame.
        let named = event.isEmpty || event == "message" ? "output" : event
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        // A queue refusal arrives as a 200 frame carrying its own status.
        if let status = root["statusCodeValue"] as? Int, status != 200 {
            let body = String(describing: root["body"] ?? "")
            return [errorChunk("Trae answered \(status): \(body.prefix(240))")]
        }
        switch named {
        case "error":
            let code = root["code"].map { String(describing: $0) } ?? ""
            let message = root["message"] as? String ?? "unknown"
            return [errorChunk("Trae \(code.isEmpty ? "error" : "code \(code)"): \(message)")]

        case "token_usage":
            func number(_ key: String) -> Int { (root[key] as? NSNumber)?.intValue ?? 0 }
            return [chunk([
                "choices": [Any](),
                "usage": [
                    "prompt_tokens": number("prompt_tokens"),
                    "completion_tokens": number("completion_tokens"),
                    "total_tokens": number("total_tokens"),
                ],
            ])]

        case "done":
            return [chunk(["choices": [[
                "index": 0,
                "delta": [String: Any](),
                "finish_reason": finishReason(root["finish_reason"] as? String),
            ]]])]

        case "output":
            var out: [String] = []
            if let reasoning = root["reasoning_content"] as? String, !reasoning.isEmpty {
                out.append(deltaChunk(["reasoning_content": reasoning]))
            }
            if let text = root["response"] as? String, !text.isEmpty {
                out.append(deltaChunk(["content": text]))
            }
            for (position, call) in (root["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
                if let frame = toolCallChunk(call, position: position) { out.append(frame) }
            }
            return out

        default:
            return []
        }
    }

    /// The finish reason callers read. The gate labels a tool-call turn `stop`
    /// as often as `tool_calls`, so a turn that streamed calls says it called
    /// them.
    static func finishReason(_ raw: String?) -> String {
        let reason = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        switch reason {
        case "", "stop", "end": return "stop"
        case "length", "max_tokens": return "length"
        case "tool_calls", "function_call": return "tool_calls"
        default: return reason
        }
    }

    private static func toolCallChunk(_ call: [String: Any], position: Int) -> String? {
        let function = (call["function_call"] ?? call["function"]) as? [String: Any] ?? [:]
        var fields: [String: Any] = [:]
        if let name = function["name"] as? String, !name.isEmpty { fields["name"] = name }
        if let arguments = function["arguments"] as? String, !arguments.isEmpty {
            fields["arguments"] = arguments
        }
        guard !fields.isEmpty else { return nil }
        var entry: [String: Any] = [
            "index": (call["index"] as? NSNumber)?.intValue ?? position,
            "type": "function",
            "function": fields,
        ]
        if let id = call["id"] as? String, !id.isEmpty { entry["id"] = id }
        return deltaChunk(["tool_calls": [entry]])
    }

    private static func deltaChunk(_ delta: [String: Any]) -> String {
        chunk(["choices": [["index": 0, "delta": delta, "finish_reason": NSNull()]]])
    }

    private static func errorChunk(_ message: String) -> String {
        chunk(["error": ["message": message, "type": "upstream_error"]])
    }

    private static func chunk(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

/// Per-request normalizer shared by text completions and the agent transport.
/// A finish reason closes the turn, not the transport: usage may follow it.
struct TraeStreamState {
    private(set) var streamEnded = false
    private(set) var finishSeen = false
    private var event = ""
    private var data: [String] = []
    private var answered = false
    private var calledTools = false
    private var doneEmitted = false
    private var tools = TraeToolState()

    mutating func consume(_ line: String) throws -> [String] {
        guard !streamEnded else { return [] }
        if line.hasPrefix("event:") {
            let flushed = try flush()
            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return flushed
        }
        if line.hasPrefix("data:") {
            data.append(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
            // AsyncBytes.lines can omit blank lines. Flush complete JSON eagerly,
            // retaining fragments for multiline SSE until a document is complete.
            let joined = data.joined(separator: "\n")
            if joined == "[DONE]" || (try? JSONSerialization.jsonObject(with: Data(joined.utf8))) != nil {
                return try flush()
            }
        }
        if line.isEmpty { return try flush() }
        return []
    }

    private mutating func flush() throws -> [String] {
        guard !data.isEmpty else { return [] }
        let payload = data.joined(separator: "\n")
        let frameEvent = event
        data.removeAll(keepingCapacity: true)
        event = "" // An event name belongs to exactly one frame.
        if payload == "[DONE]" {
            var out = finishTurn(reason: calledTools ? "tool_calls" : "stop")
            streamEnded = true
            if !doneEmitted { out.append("data: [DONE]"); doneEmitted = true }
            return out
        }
        guard var json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
            throw LLMError.providerError(message: "Trae returned a malformed stream frame.")
        }
        // Refusals can arrive with HTTP 200. Never expose the vendor's raw
        // error body: it can contain account credentials.
        if frameEvent == "error" || json["error"] != nil
            || ((json["statusCodeValue"] as? Int).map { $0 != 200 } ?? false) {
            throw LLMError.providerError(message: "Trae refused the streaming request. Check the account and model.")
        }
        if let calls = json["tool_calls"] as? [[String: Any]], !calls.isEmpty {
            calledTools = true
            json["tool_calls"] = tools.normalize(calls)
        }
        if frameEvent == "done" {
            let reason = TraeDialect.finishReason(json["finish_reason"] as? String)
            return finishTurn(reason: calledTools && reason == "stop" ? "tool_calls" : reason)
        }
        let encoded = try JSONSerialization.data(withJSONObject: json)
        let chunks = TraeDialect.translate(event: frameEvent, payload: String(decoding: encoded, as: UTF8.self))
        if frameEvent.isEmpty || frameEvent == "message" || frameEvent == "output" {
            answered = answered || !chunks.isEmpty
        }
        return chunks.map { "data: " + $0 }
    }

    private mutating func finishTurn(reason: String) -> [String] {
        guard !finishSeen else { return [] }
        finishSeen = true
        let frame: [String: Any] = ["choices": [[
            "index": 0, "delta": [String: Any](), "finish_reason": reason,
        ]]]
        let encoded = try! JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
        return ["data: " + String(decoding: encoded, as: UTF8.self)]
    }

    mutating func finish() throws -> [String] {
        var out = try flush()
        if !finishSeen {
            guard answered || calledTools else {
                throw LLMError.providerError(message: "Trae ended without an answer.")
            }
            out += finishTurn(reason: calledTools ? "tool_calls" : "length")
        }
        streamEnded = true
        if !doneEmitted { out.append("data: [DONE]"); doneEmitted = true }
        return out
    }
}

/// Stable indices and exactly one id/name start for the existing agent parser.
/// Metadata can repeat or arrive after argument fragments.
private struct TraeToolState {
    private struct Call {
        var id = ""
        var name = ""
        var pendingArguments = ""
        var started = false
    }
    private var calls: [Int: Call] = [:]
    private var indicesByID: [String: Int] = [:]
    private var lastIndex: Int?

    mutating func normalize(_ incoming: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for (position, raw) in incoming.enumerated() {
            let function = (raw["function_call"] ?? raw["function"]) as? [String: Any] ?? [:]
            let id = raw["id"] as? String ?? ""
            let name = function["name"] as? String ?? ""
            let index: Int
            if let explicit = (raw["index"] as? NSNumber)?.intValue { index = explicit }
            else if !id.isEmpty, let known = indicesByID[id] { index = known }
            else if !id.isEmpty { index = (calls.keys.max() ?? -1) + 1 }
            else if incoming.count > 1 { index = position }
            else if !name.isEmpty, let known = calls.first(where: { $0.value.name == name })?.key { index = known }
            else { index = lastIndex ?? 0 }
            var call = calls[index] ?? Call()
            if !id.isEmpty { indicesByID[id] = index; if !call.started { call.id = id } }
            if !name.isEmpty && !call.started { call.name = name }
            if let arguments = function["arguments"] as? String {
                call.pendingArguments += arguments
            } else if let arguments = function["arguments"], !(arguments is NSNull),
                      JSONSerialization.isValidJSONObject(arguments),
                      let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) {
                call.pendingArguments += String(decoding: data, as: UTF8.self)
            }
            if !call.name.isEmpty {
                var fields: [String: Any] = [:]
                var entry: [String: Any] = ["index": index, "type": "function"]
                if !call.started {
                    if call.id.isEmpty { call.id = "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
                    entry["id"] = call.id
                    fields["name"] = call.name
                    call.started = true
                }
                if !call.pendingArguments.isEmpty {
                    fields["arguments"] = call.pendingArguments
                    call.pendingArguments = ""
                }
                if !fields.isEmpty { entry["function"] = fields; result.append(entry) }
            }
            calls[index] = call
            lastIndex = index
        }
        return result
    }
}
