import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure(message: message) }
}

private func jsonObject(_ text: String) throws -> [String: Any] {
    guard let data = text.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TestFailure(message: "Expected JSON object: \(text)")
    }
    return object
}

private func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// The dialect returns bare chunk JSON; the stateful normalizer prefixes it
/// with `data: `. Accept both so each layer is asserted at its own boundary.
private func frameObject(_ line: String) throws -> [String: Any] {
    if line.hasPrefix("data: ") { return try jsonObject(String(line.dropFirst(6))) }
    if line.hasPrefix("data:") { return try jsonObject(String(line.dropFirst(5))) }
    return try jsonObject(line)
}

private func choice(_ frame: [String: Any]) throws -> [String: Any] {
    guard let choices = frame["choices"] as? [[String: Any]],
          let first = choices.first else {
        throw TestFailure(message: "Expected a choice frame: \(frame)")
    }
    return first
}

private func emit(_ state: inout TraeStreamState, event: String, payload: String) throws -> [String] {
    _ = try state.consume("event: \(event)")
    return try state.consume("data: \(payload)")
}

private func expectThrow(_ body: () throws -> Void, _ message: String) throws {
    var didThrow = false
    do {
        try body()
    } catch {
        didThrow = true
    }
    try check(didThrow, message)
}

/// URLSession hands a URLProtocol the body as a stream, not `httpBody`.
private func requestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private final class TraeMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: TestFailure(message: "Mock handler was not installed"))
            return
        }
        let result = handler(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: result.0,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func testSitesAndHeaders() throws {
    let china = TraeAPI.Site.china
    let international = TraeAPI.Site.international

    try check(china.apiOrigin == "https://trae-api-cn.mchost.guru", "CN chat origin changed")
    try check(international.apiOrigin == "https://coresg-normal.trae.ai", "International chat origin changed")
    try check(china.fixedLoginHost == "https://www.trae.cn", "CN fixed login host changed")
    try check(international.fixedLoginHost == nil, "International login must come from guidance")
    try check(china.guidanceURLs.isEmpty, "CN must not use international guidance URLs")
    try check(international.guidanceURLs.count == 3, "International guidance fallback list changed")
    try check(international.guidanceURLs[0].contains("marscode.com"), "International guidance order changed")

    try check(china.exchangeOrigins == ["https://api.trae.cn", "https://api.trae.com.cn"], "CN private account origins changed")
    try check(international.exchangeOrigins == [
        "https://grow-normal.trae.ai",
        "https://growsg-normal.trae.ai",
        "https://grow-normal.traeapi.us",
        "https://api.marscode.com",
        "https://api.trae.ai",
        "https://www.trae.ai",
    ], "International private account origins changed")

    try check(china.pluginVersion == "2.3.83560", "CN plugin profile changed")
    try check(china.appVersion == "3.3.100", "CN app profile changed")
    try check(china.deviceBrand.isEmpty && china.osInfo == "windows" && china.channelName == "common", "CN device profile changed")
    try check(international.pluginVersion == "local", "International plugin profile changed")
    try check(international.appVersion == "3.5.54", "International app profile changed")
    try check(international.deviceBrand == "unknown" && international.osInfo == "unknown", "International device profile changed")
    try check(international.fixedDeviceID == "0" && international.machineIsUUID, "International device identity profile changed")

    let identity = TraeAPI.clientHeaders()
    try check(identity["x-plugin-channel"] == "icube-ai", "Trae plugin channel header changed")
    try check(identity["x-device-type"] == "ios" && identity["x-device-cpu"] == "arm64", "Trae device headers changed")
    try check(identity["x-ide-version"] == TraeAPI.ideVersion, "Trae IDE version header changed")
    try check(identity["x-ide-version-code"] == String(TraeAPI.versionCode), "Trae IDE version code header changed")
    try check(identity["User-Agent"] == "Trae/\(TraeAPI.ideVersion)", "Trae User-Agent changed")

    let account = TraeAPI.accountHeaders(token: "token", userID: "user-123", machineID: nil, deviceID: "0")
    try check(account["Authorization"] == "Cloud-IDE-JWT token", "Trae Authorization scheme changed")
    try check(account["X-Ide-Token"] == "token" && account["X-Cloudide-Token"] == "token", "Trae token fan-out changed")
    try check(account["x-uid"] == "user-123" && account["x-device-id"] == "0", "Trae account identity headers changed")
    try check(account["x-machine-id"]?.count == 32, "Derived machine id must remain 32 hex characters")
    try check(TraeAPI.chatURL(origin: international.apiOrigin)?.absoluteString == "https://coresg-normal.trae.ai/api/agent/v3/llm_utils_chat", "International chat path changed")
    try check(TraeAPI.directoryURL(origin: china.apiOrigin)?.absoluteString == "https://trae-api-cn.mchost.guru/api/ide/v1/get_detail_param", "Directory path changed")
    // The roster host is not always the chat host: China splits them, the
    // international build has mirrored gateways.
    try check(TraeAPI.remoteOrigins(chatOrigin: china.apiOrigin).first == "https://solo.trae.cn", "CN roster host changed")
    try check(TraeAPI.remoteOrigins(chatOrigin: international.apiOrigin).contains("https://coresg-normal.trae.ai"), "International roster host changed")
    try check(TraeAPI.directoryFunctions.count >= 5, "Only a subset of the chat functions is asked")
}

private func testMendedBody() throws {
    let tool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "lookup",
            "description": "Look up a value",
            "parameters": [
                "type": "object",
                "properties": ["query": ["type": "string"]],
                "required": ["query"],
            ],
        ],
    ]
    let call: [String: Any] = [
        "id": "call-1",
        "type": "function",
        "function": ["name": "lookup", "arguments": "{\"query\":\"x\"}"],
    ]
    let root: [String: Any] = [
        "messages": [
            ["role": "developer", "content": "follow policy"],
            ["role": "user", "content": [
                ["type": "text", "text": "hello"],
                ["type": "image_url", "image_url": ["url": "private-image"]],
            ]],
            ["role": "assistant", "content": NSNull()],
            ["role": "assistant", "content": "", "tool_calls": [call]],
        ],
        "tools": [tool],
        "reasoning_effort": "high",
    ]

    let body = TraeAPI.mendedBody(root, model: "glm-5.3", function: "solo_work_lite")
    try check(body["model"] as? String == "glm-5.3", "Body model was not preserved")
    try check(body["config_name"] as? String == "glm-5.3", "Body config_name must follow model")
    try check(body["function"] as? String == "solo_work_lite", "Directory function was not carried into chat body")
    try check(body["stream"] as? Bool == true, "Trae body must stream")
    try check(body["reasoning_effort"] as? String == "high", "Reasoning effort was dropped")

    let messages = body["messages"] as! [[String: Any]]
    try check(messages.count == 3, "Empty assistant turn without calls should be removed")
    try check(messages[0]["role"] as? String == "system", "Developer role was not mapped to system")
    try check((messages[0]["content"] as? [[String: Any]])?.first?["text"] as? String == "follow policy", "System text block was malformed")
    try check((messages[1]["content"] as? [[String: Any]])?.count == 1, "Non-text content must be dropped")
    try check(messages[2]["function_call"] != nil && messages[2]["tool_calls"] == nil, "Assistant tool calls were not mapped to function_call")

    let tools = body["tools"] as! [[String: Any]]
    let function = tools[0]["function"] as! [String: Any]
    try check(function["parameters"] is String, "Trae tool parameters must be a JSON string")
    let parameters = try jsonObject(function["parameters"] as! String)
    try check(parameters["type"] as? String == "object", "Tool parameter JSON was not preserved")

    // Auto is the inline_chat scene with NO model name. Sending
    // `config_name: "auto"` is what made the picker row unusable.
    let autoBody = TraeAPI.mendedBody(["messages": [["role": "user", "content": "hi"]]],
                                      model: "auto", function: "solo_work_remote")
    try check(autoBody["function"] as? String == "inline_chat", "Auto must use the inline_chat scene")
    try check(autoBody["model"] == nil, "Auto must not send a model name")
    try check(autoBody["config_name"] == nil, "Auto must not send config_name")
    try check(TraeAPI.isAuto("auto") && TraeAPI.isAuto(" AUTO ") && TraeAPI.isAuto(""), "Auto detection is case/whitespace sensitive")
    try check(!TraeAPI.isAuto("gpt-6.1-sol"), "A named model must not be treated as Auto")

    let blank = TraeAPI.textBlocks(NSNull())
    try check(blank.count == 1 && blank[0]["text"] as? String == "", "Null content must become one empty text block")
    let imageOnly = TraeAPI.textBlocks([["type": "image_url", "url": "x"]])
    try check(imageOnly.count == 1 && imageOnly[0]["text"] as? String == "", "Image-only content must become an empty text block")
}

private func testDirectoryRequestAndRoster() async throws {
    let headers = ["X-Test": "yes"]
    let request = TraeAPI.directoryRequest(origin: "https://mock.trae.test", function: "solo_work_lite", headers: headers)!
    try check(request.httpMethod == "POST", "Directory request must be POST")
    try check(request.value(forHTTPHeaderField: "X-Test") == "yes", "Directory request dropped caller headers")
    let directoryBody = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
    try check(directoryBody["function"] as? String == "solo_work_lite", "Directory function was not encoded")
    try check(directoryBody["need_prompt"] as? Bool == false, "Directory prompt flag changed")

    TraeMockURLProtocol.handler = { request in
        let url = request.url?.absoluteString ?? ""
        if url.contains("/api/remote/v1/models") {
            // The SOLO web directory: one document, grouped by function, which
            // is what the vendor's own picker renders.
            let groups: [[String: Any]] = [
                ["function": "solo_work_lite", "models": [
                    ["name": "gpt-6.1-sol", "display_name": "GPT-6.1-Sol",
                     "context_window_tokens": ["dev": 262_144],
                     "features": ["reasoning": ["enable": true]]],
                    ["name": "shared", "display_name": "Lite shared"],
                ]],
                ["function": "solo_work_remote", "models": [
                    ["name": "shared", "display_name": "Remote shared"],
                    ["name": "remote-only", "display_name": "Remote only",
                     "context_window_tokens": ["dev": 9000]],
                    ["name": "search_agent_internal"],
                    ["name": "custom_model_hidden"],
                ]],
                ["function": "chat_v3", "models": [
                    ["name": "Seed-2.1-Turbo", "display_name": "Seed-2.1-Turbo"],
                ]],
                ["function": "code_review_summary", "models": [
                    ["name": "review-helper", "display_name": "Review helper"],
                ]],
            ]
            return (200, (try? jsonData(["code": 0, "data": ["list": groups]])) ?? Data())
        }
        let body = (try? JSONSerialization.jsonObject(with: requestBody(request))) as? [String: Any] ?? [:]
        let function = body["function"] as? String ?? ""
        let entries: [[String: Any]] = function == "solo_work_remote" ? [
            ["config_name": "shared", "display_config": ["display_name": "Remote shared"], "model_detail_list": [["max_tokens": 111]]],
            ["config_name": "remote-only", "display_config": ["model_capability": "reasoning_model"], "context_window_tokens": ["dev": 9000]],
        ] : []
        let document: [String: Any] = ["config_info_list": entries]
        return (200, (try? jsonData(document)) ?? Data())
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TraeMockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { TraeMockURLProtocol.handler = nil }

    let roster = await TraeAPI.roster(origin: "https://mock.trae.test", headers: headers, session: session)
    // Declared function priority wins over response order, and the picker's
    // models are present — not just whatever get_detail_param happened to list.
    try check(roster.map(\.id) == ["shared", "remote-only", "gpt-6.1-sol", "Seed-2.1-Turbo"],
              "Directory roster did not merge in declared precedence: \(roster.map(\.id))")
    try check(roster.map(\.function) == ["solo_work_remote", "solo_work_remote", "solo_work_lite", "chat_v3"],
              "Directory function provenance was lost: \(roster.map(\.function))")
    try check(roster[1].reasoning && roster[1].contextWindow == 9000, "Directory capability metadata was lost")
    try check(roster[0].maxTokens == 111, "get_detail_param metadata did not refine the directory row")
    try check(roster[2].reasoning, "Reasoning capability was not read from the directory")
    let cache = TraeAPI.ModelFunctions()
    cache.store(roster, identity: "origin-a:account-a")
    try check(cache.function(for: "shared") == "solo_work_remote", "Model function precedence was not cached")
    try check(cache.function(for: "gpt-6.1-sol") == "solo_work_lite", "Model function provenance was not cached")
    try check(cache.function(for: "missing") == TraeAPI.defaultFunction, "Unknown models need the safe default function")
    try check(!cache.needsDirectory(identity: "origin-a:account-a"), "Matching directory identity should be cached")
    try check(cache.needsDirectory(identity: "origin-b:account-a"), "Origin must participate in directory cache identity")
}

private func testDialectAndStreamState() throws {
    let output = TraeDialect.translate(event: "output", payload: #"{"response":"hello","reasoning_content":"think"}"#)
    try check(output.count == 2, "Output should produce reasoning and text chunks")
    let reasoningFrame = try frameObject(output[0])
    let reasoningChoice = try choice(reasoningFrame)
    let reasoningDelta = reasoningChoice["delta"] as? [String: Any]
    try check(reasoningDelta?["reasoning_content"] as? String == "think", "Reasoning chunk was malformed")
    let textFrame = try frameObject(output[1])
    let textChoice = try choice(textFrame)
    let textDelta = textChoice["delta"] as? [String: Any]
    try check(textDelta?["content"] as? String == "hello", "Text chunk was malformed")

    var state = TraeStreamState()
    _ = try emit(&state, event: "output", payload: #"{"reasoning_content":"think","response":"hello"}"#)
    let usage = try emit(&state, event: "token_usage", payload: #"{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}"#)
    let usageFrame = try frameObject(usage[0])
    let usageObject = usageFrame["usage"] as! [String: Any]
    try check((usageObject["total_tokens"] as? NSNumber)?.intValue == 7, "Usage frame lost token counts")
    let done = try emit(&state, event: "done", payload: #"{"finish_reason":"stop"}"#)
    let doneFrame = try frameObject(done[0])
    let doneChoice = try choice(doneFrame)
    try check(doneChoice["finish_reason"] as? String == "stop", "Done frame had the wrong finish reason")
    let eof = try state.finish()
    try check(eof == ["data: [DONE]"], "EOF should emit one terminal marker after done")
    try check(try state.consume("data: [DONE]").isEmpty, "Frames after stream end must be ignored")

    var toolState = TraeStreamState()
    let firstTool = try emit(&toolState, event: "output", payload: #"{"tool_calls":[{"id":"call-1","index":0,"function":{"name":"search","arguments":"{\"q\":"}}]}"#)
    let firstToolFrame = try frameObject(firstTool[0])
    let firstChoice = try choice(firstToolFrame)
    let firstEntry = (firstChoice["delta"] as! [String: Any])["tool_calls"] as! [[String: Any]]
    let firstFunction = firstEntry[0]["function"] as! [String: Any]
    try check(firstEntry[0]["index"] as? Int == 0 && firstEntry[0]["id"] as? String == "call-1", "Tool call identity was not stable")
    try check(firstFunction["name"] as? String == "search" && firstFunction["arguments"] as? String == "{\"q\":", "First tool fragment was malformed")
    let secondTool = try emit(&toolState, event: "output", payload: #"{"tool_calls":[{"id":"call-1","index":0,"function":{"name":"search","arguments":"\"x\"}"}}]}"#)
    let secondFrame = try frameObject(secondTool[0])
    let secondChoice = try choice(secondFrame)
    let secondEntry = ((secondChoice["delta"] as! [String: Any])["tool_calls"] as! [[String: Any]])[0]
    let secondFunction = secondEntry["function"] as! [String: Any]
    try check(secondEntry["index"] as? Int == 0, "Repeated tool metadata changed index")
    try check(secondFunction["name"] == nil && secondFunction["arguments"] as? String == "\"x\"}", "Repeated tool metadata should emit only argument fragments")
    let toolDone = try emit(&toolState, event: "done", payload: #"{"finish_reason":"stop"}"#)
    let toolDoneFrame = try frameObject(toolDone[0])
    let toolDoneChoice = try choice(toolDoneFrame)
    try check(toolDoneChoice["finish_reason"] as? String == "tool_calls", "Tool turn should finish as tool_calls")

    var independent = TraeStreamState()
    let independentOutput = try emit(&independent, event: "output", payload: #"{"tool_calls":[{"id":"other","function":{"name":"other_tool","arguments":"{}"}}]}"#)
    let independentFrame = try frameObject(independentOutput[0])
    let independentChoice = try choice(independentFrame)
    let independentEntry = (((independentChoice["delta"] as! [String: Any])["tool_calls"] as! [[String: Any]])[0])
    try check(independentEntry["index"] as? Int == 0, "Tool state leaked between requests")
    try check((independentEntry["function"] as! [String: Any])["name"] as? String == "other_tool", "Tool name leaked between requests")

    var errorState = TraeStreamState()
    try expectThrow({ _ = try emit(&errorState, event: "error", payload: #"{"code":401,"message":"private details"}"#) }, "Streaming error frame must fail the request")
    var emptyState = TraeStreamState()
    try expectThrow({ _ = try emptyState.finish() }, "Empty EOF must fail instead of fabricating an answer")
    let directError = TraeDialect.translate(event: "error", payload: #"{"code":401,"message":"denied"}"#)
    let directErrorFrame = try frameObject(directError[0])
    try check(directError.count == 1 && directErrorFrame["error"] != nil, "Dialect error translation disappeared")
    try check(TraeDialect.finishReason("max_tokens") == "length", "max_tokens finish reason changed")
    try check(TraeDialect.finishReason("function_call") == "tool_calls", "function_call finish reason changed")
}

private func runAll() async throws {
    try testSitesAndHeaders()
    try testMendedBody()
    try await testDirectoryRequestAndRoster()
    try testDialectAndStreamState()
}

do {
    try await runAll()
    print("Trae international regression tests passed")
} catch {
    fatalError("Trae international regression tests failed: \(error)")
}
