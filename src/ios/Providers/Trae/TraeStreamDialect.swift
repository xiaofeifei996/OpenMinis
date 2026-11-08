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
    /// Rewrite one `data:` payload into zero or more OpenAI chunk payloads.
    /// `event` is the SSE `event:` field (empty when the stream carries none).
    func translate(event: String, payload: String) -> [String]
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
