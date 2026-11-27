#!/usr/bin/env python3
"""Compile the unmodified TodayProvider.swift and run offline Swift fixtures.

macOS: python3 scripts/test_today_protocol.py --require-swift
No swiftc: exit 77 (SKIP), or exit 1 with --require-swift; never report PASS.
Only app dependency types are stubbed. Private wire types/methods are exercised
in the same Swift source file; all URLSession traffic is intercepted locally.
"""
from pathlib import Path
import argparse
import hashlib
import platform
import re
import shutil
import subprocess
import sys
import tempfile

EXPECTED_TESTS = 18


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-swift', action='store_true',
                        help='Treat missing swiftc as a failure (for CI).')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    provider = root / 'src/ios/Providers/TodayProvider.swift'
    if not provider.is_file():
        print(f'FAIL: missing source: {provider}', file=sys.stderr)
        return 1
    compiler = shutil.which('swiftc')
    if not compiler:
        print('SKIP: swiftc unavailable; 0 Swift fixtures executed. '
              'This is NOT a successful runtime test.', file=sys.stderr)
        return 1 if args.require_swift else 77
    source = provider.read_bytes()
    digest = hashlib.sha256(source).hexdigest()
    print(f'TodayProvider.swift SHA256: {digest}', flush=True)
    try:
        version = subprocess.run([compiler, '--version'], check=True,
                                 text=True, capture_output=True, timeout=20)
        print(version.stdout.strip(), flush=True)
        with tempfile.TemporaryDirectory(prefix='today-protocol-') as folder:
            folder = Path(folder)
            swift = folder / 'main.swift'
            binary = folder / 'today-fixtures'
            # Byte-for-byte concatenation, not extraction, regex rewriting,
            # access-level replacement, or a reimplementation of the provider.
            swift.write_bytes(SUPPORT.encode('utf-8') + b'\n' + source + b'\n'
                              + FIXTURES.encode('utf-8'))
            command = [compiler, '-swift-version', '5', '-parse-as-library',
                       str(swift), '-o', str(binary)]
            if sys.platform == 'darwin':
                # URLSession.data(for:) requires macOS 12, including on older
                # Xcode installations whose default deployment target is lower.
                command[1:1] = ['-target', f'{platform.machine()}-apple-macosx12.0']
            print('Compiling real provider + minimal stubs + fixtures...', flush=True)
            compiled = subprocess.run(command, text=True, capture_output=True, timeout=180)
            if compiled.stdout:
                print(compiled.stdout, end='')
            if compiled.stderr:
                print(compiled.stderr, end='', file=sys.stderr)
            if compiled.returncode:
                print('FAIL: real TodayProvider.swift did not compile.', file=sys.stderr)
                return 1
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=30)
            print(result.stdout, end='')
            if result.stderr:
                print(result.stderr, end='', file=sys.stderr)
            summary = re.search(r'^TODAY_FIXTURES passed=(\d+) failed=(\d+)$',
                                result.stdout, re.MULTILINE)
            if (result.returncode or not summary
                    or tuple(map(int, summary.groups())) != (EXPECTED_TESTS, 0)):
                print('FAIL: Swift fixture failure or incomplete test run.', file=sys.stderr)
                return 1
        if provider.read_bytes() != source:
            print('FAIL: provider changed during the test; rerun against a stable source.',
                  file=sys.stderr)
            return 1
    except (OSError, subprocess.SubprocessError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1
    print(f'PASS: {EXPECTED_TESTS} real Swift fixtures; no live network.', flush=True)
    return 0


# Self-contained stubs/fixtures; no app source is rewritten.
SUPPORT = r'''// Only application dependencies are stubbed; no Today protocol logic lives here.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

protocol LLMProvider {
    var name: String { get }
    var model: LLMModel { get set }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error>
}
enum ModelModality: Sendable { case textOnly }
struct LLMModel: Sendable {
    let id: String
    let displayName: String
    let provider: String
    var modalityOverride: ModelModality? = nil
    var contextWindow: Int? = nil
    var maxOutputTokens: Int? = nil
    var supportsReasoning: Bool? = nil
}
struct LLMMessage: Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let content: String
}
struct LLMUsage: Sendable {}
struct LLMResponse: Sendable {
    let text: String
    let stopReason: String?
    let usage: LLMUsage?
}
enum LLMStreamChunk: Sendable {
    case started
    case text(String)
    case finished(stopReason: String?)
}
enum ProviderType {
    case today
    var displayName: String { "Today AI" }
}
// Naming policy belongs to the app, not the wire protocol under test.
func modelDisplayName(from id: String) -> String { id }
'''

FIXTURES = r'''// Appended after the exact provider bytes so file-private wire types stay real.
private extension TodayClient {
    static func fixtureCookie(_ value: String) -> String { normalizeCookie(value) }
    func fixtureSelect(_ value: String) async throws { try await selectModel(value) }
}

private struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureFailure(message) }
}
private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}
private func object(_ data: Data) throws -> [String: Any] {
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw FixtureFailure("expected JSON object")
    }
    return result
}
private func body(_ request: URLRequest) throws -> [String: Any] {
    if let data = request.httpBody { return try object(data) }
    guard let stream = request.httpBodyStream else { throw FixtureFailure("missing request body") }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw FixtureFailure("cannot read request body stream") }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return try object(data)
}
private struct Step {
    let method: String
    let path: String
    let status: Int
    let reply: (URLRequest) throws -> String
    init(_ method: String, _ path: String, _ json: String = "{}", status: Int = 200,
         check: @escaping (URLRequest) throws -> Void = { _ in }) {
        self.method = method; self.path = path; self.status = status
        self.reply = { request in try check(request); return json }
    }
    init(_ method: String, _ path: String, reply: @escaping (URLRequest) throws -> String) {
        self.method = method; self.path = path; self.status = 200; self.reply = reply
    }
}
// Catch ALL requests, not just known hosts. Unknown requests fail closed;
// neither a fixture mismatch nor an empty queue can fall through to the network.
private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var steps: [Step] = []
    private static var issues: [String] = []
    static func install(_ values: [Step]) {
        lock.lock(); defer { lock.unlock() }
        steps = values; issues = []
    }
    static func finish() throws {
        lock.lock(); defer { lock.unlock() }
        try expect(steps.isEmpty && issues.isEmpty,
                   "network fixture incomplete: \(steps.count) unused; \(issues.joined(separator: "; "))")
    }
    private static func consume(_ request: URLRequest) throws -> Step {
        lock.lock(); defer { lock.unlock() }
        guard !steps.isEmpty else { throw FixtureFailure("unexpected request: \(request.url?.path ?? "nil")") }
        let step = steps.removeFirst()
        try expect(request.url?.scheme == "https" && request.url?.host == "todayai.cn", "wrong service URL")
        try expect(request.httpMethod == step.method && request.url?.path == step.path,
                   "expected \(step.method) \(step.path), got \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
        return step
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let step = try Self.consume(request)
            let data = Data(try step.reply(request).utf8)
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: step.status,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"]) else {
                throw FixtureFailure("cannot create local response")
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            Self.lock.lock(); Self.issues.append(String(describing: error)); Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
private final class Suite {
    var passed = 0
    var failed = 0
    func run(_ name: String, _ test: () async throws -> Void) async {
        FixtureURLProtocol.install([])
        do {
            try await test()
            try FixtureURLProtocol.finish()
            passed += 1
            print("PASS \(name)")
        } catch {
            failed += 1
            print("FAIL \(name): \(error)")
            do { try FixtureURLProtocol.finish() }
            catch { print("  \(error)") }
        }
    }
}
private let tokenStep = Step("POST", "/api/token", #"{"token":"fixture-token","expiresIn":3600}"#) { request in
    try expect(request.value(forHTTPHeaderField: "Cookie") == "__Secure-better-auth.session_token=YWJjZA==", "base64 cookie padding lost")
    let json = try body(request)
    try expect(json["audience"] as? String == "https://api.todayai.cn", "token audience")
    try expect(json["expiresIn"] as? Int == 3600, "token lifetime")
}
private let history = #"""
{"data":{"items":[
 {"role":"assistant","state":"completed","originClientMessageId":"old-turn","body":{"parts":[{"messageType":"text","content":{"text":"OLD ANSWER"}}]}},
 {"role":"user","clientMessageId":"CURRENT","body":{"parts":[{"messageType":"text","content":{"text":"USER ECHO"}}]}},
 {"role":"assistant","state":"COMPLETED","isFinal":true,"originClientMessageIds":["CURRENT"],"body":{"parts":[
  {"messageType":"turn","content":{"text":[{"role":"user","text":"do not emit"}]}},
  {"messageType":"future-kind","content":{"text":"HIDDEN"}},
  {"messageType":"future-kind","content":[1,2,3]},
  {"messageType":"text","content":{"text":"correct "}},
  {"content":null},
  {"messageType":"text","content":{"text":"answer"}}
 ]}}
]}}
"""#

@main private enum TodayProtocolFixtures {
    static func main() async {
        guard URLProtocol.registerClass(FixtureURLProtocol.self) else {
            print("FAIL: cannot register offline URLProtocol; refusing to run")
            exit(1)
        }
        defer { URLProtocol.unregisterClass(FixtureURLProtocol.self) }
        let suite = Suite()
        await suite.run("canonical send body and clientMessageId") {
            let request = TodaySendRequest(text: "你好\nfixture", clientMessageID: "client-fixed")
            let json = try object(JSONEncoder().encode(request))
            try expect(Set(json.keys) == Set(["body", "clientMessageId", "isMainChat"]), "non-canonical send keys")
            try expect(json["clientMessageId"] as? String == "client-fixed", "client ID changed")
            try expect(json["isMainChat"] as? Bool == true, "missing main-chat flag")
            let parts = (json["body"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            try expect(parts.count == 1, "expected one canonical text part")
            guard let part = parts.first else { throw FixtureFailure("missing part") }
            try expect(Set(part.keys) == Set(["id", "type", "text"]), "legacy messageType/content in outbound part")
            try expect(part["type"] as? String == "text" && part["text"] as? String == "你好\nfixture", "wrong canonical text")
            try expect(UUID(uuidString: part["id"] as? String ?? "") != nil, "part ID is not UUID")
        }
        await suite.run("context retains caller history and system prompt") {
            let value = TodaySendRequest.context(messages: [
                .init(role: .user, content: "first"), .init(role: .assistant, content: "reply"),
                .init(role: .user, content: ""), .init(role: .user, content: "next")
            ], systemPrompt: "system")
            try expect(value == "[system]\nsystem\n\n[user]\nfirst\n\n[assistant]\nreply\n\n[user]\nnext", "history was dropped or mixed")
            try expect(TodaySendRequest.context(messages: [], systemPrompt: nil).isEmpty, "empty context")
        }
        await suite.run("root token and relative expiration") {
            let before = Date()
            let value = try decode(TodayTokenResponse.self, #"{"token":"root","expiresIn":3600}"#)
            try expect(value.token == "root", "root token")
            try expect(abs(value.expiration.timeIntervalSince(before) - 3600) < 3, "relative expiration")
        }
        await suite.run("data token and absolute seconds expiration") {
            let value = try decode(TodayTokenResponse.self, #"{"data":{"token":"nested","expiresAt":2000000000}}"#)
            try expect(value.token == "nested" && value.expiration.timeIntervalSince1970 == 2_000_000_000, "nested token/expiration")
        }
        await suite.run("millisecond expiration") {
            let value = try decode(TodayTokenResponse.self, #"{"token":"ms","expiresAt":2000000000000}"#)
            try expect(value.expiration.timeIntervalSince1970 == 2_000_000_000, "milliseconds not converted")
        }
        await suite.run("ISO8601 expiration") {
            let value = try decode(TodayTokenResponse.self, #"{"data":{"token":"iso","expiresAt":"2033-05-18T03:33:20Z"}}"#)
            try expect(value.expiration.timeIntervalSince1970 == 2_000_000_000, "ISO expiration")
        }
        await suite.run("JWT expiration uses earliest available deadline") {
            let payload = Data(#"{"exp":1900000000,"fixture":"??"}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let data = try JSONSerialization.data(withJSONObject: ["data": [
                "token": "e30.\(payload).signature", "expiresAt": 2_000_000_000
            ]])
            let value = try JSONDecoder().decode(TodayTokenResponse.self, from: data)
            try expect(value.expiration.timeIntervalSince1970 == 1_900_000_000, "JWT exp ignored or longest deadline chosen")
        }
        await suite.run("nullable expiration falls back safely") {
            let before = Date()
            let value = try decode(TodayTokenResponse.self, #"{"token":"opaque","expiresAt":null,"expiresIn":null}"#)
            try expect(abs(value.expiration.timeIntervalSince(before) - 300) < 3, "fallback TTL")
        }
        await suite.run("nullable and absent model options") {
            for status in [#"{"modelOptions":null}"#, #"{"modelOptions":{"options":null}}"#,
                           #"{"modelOptions":{}}"#, "{}"] {
                let value = try decode(TodayPricingStatus.self, "{\"data\":{\"status\":\(status)}}")
                try expect((value.data.status.modelOptions?.options ?? []).isEmpty, "null options must be empty")
            }
            let value = try decode(TodayPricingStatus.self, #"{"data":{"status":{"modelOptions":{"options":[{"id":"mode.auto","disabled":null,"title":null,"display":null}]}}}}"#)
            try expect(value.data.status.modelOptions?.options?.first?.disabled == false, "null disabled must default false")
        }
        await suite.run("root data and canonicalMessage send response envelopes") {
            for json in [
                #"{"clientMessageId":"c","conversationId":"main"}"#,
                #"{"data":{"clientMessageId":"c","conversationId":"main"}}"#,
                #"{"canonicalMessage":{"clientMessageId":"c","conversationId":"main"}}"#,
                #"{"data":{"canonicalMessage":{"clientMessageId":"c","conversationId":"main"}}}"#
            ] {
                let value = try decode(TodaySendResponse.self, json)
                try expect(value.clientMessageID == "c" && value.conversationID == "main", "response envelope not decoded")
            }
        }
        await suite.run("history turn arrays and unknown parts do not break decoding") {
            let value = try decode(TodayConversationResponse.self, history)
            try expect(value.data.items.count == 3, "history dropped items")
            let parts = value.data.items[2].body.parts
            try expect(parts.count == 6 && parts[0].content?.text == nil, "turn array not tolerated")
            let text = parts.filter { $0.messageType == "text" }.compactMap { $0.content?.text }.joined()
            try expect(text == "correct answer", "unknown or turn parts leaked into output")
            try expect(value.data.items[2].state == "completed", "state normalization")
        }
        await suite.run("origin single array and client ID never match another turn") {
            for link in [#""originClientMessageId":"turn-2""#,
                         #""originClientMessageIds":["turn-2","alias"]"#,
                         #""clientMessageId":"turn-2""#] {
                let value = try decode(TodayConversationResponse.Item.self,
                    "{\"role\":\"assistant\",\"state\":\"completed\",\(link)}")
                try expect(value.belongs(to: "turn-2"), "current origin not recognized")
                try expect(!value.belongs(to: "turn-1"), "cross-turn association")
            }
            let value = try decode(TodayConversationResponse.Item.self, #"{"role":"assistant"}"#)
            try expect(!value.belongs(to: "turn-2"), "unlinked response must not match")
        }
        await suite.run("cookie keeps base64 padding and selects only session pair") {
            let expected = "__Secure-better-auth.session_token=YWJjZA=="
            for input in ["YWJjZA==", expected, "  YWJjZA==\n",
                          "Cookie: other=x; \(expected); ignored=y"] {
                try expect(TodayClient.fixtureCookie(input) == expected, "cookie normalization or padding changed")
            }
            try expect(TodayClient.fixtureCookie("bad\r\nInjected: value").isEmpty, "header injection accepted")
        }
        await suite.run("model-option preserves mode custom and model IDs") {
            let client = TodayClient(sessionCookie: "YWJjZA==")
            let choices = [(" mode.auto ", "mode.auto"), ("custom.saved", "custom.saved"),
                           ("model.gpt-fixture", "model.gpt-fixture"), ("gpt-legacy", "model.gpt-legacy")]
            var steps = [tokenStep]
            for (_, expected) in choices {
                steps.append(Step("PUT", "/api/cloud/v1/pricing/model-option") { request in
                    let json = try body(request)
                    try expect(json["optionId"] as? String == expected, "model option prefix changed")
                    try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token", "missing API bearer")
                    return "{}"
                })
            }
            FixtureURLProtocol.install(steps)
            for (input, _) in choices { try await client.fixtureSelect(input) }
        }
        await suite.run("fetchModels filters disabled and retains account-scoped IDs") {
            FixtureURLProtocol.install([tokenStep, Step("GET", "/api/cloud/v1/pricing/status", #"""
            {"data":{"status":{"modelOptions":{"options":[
              {"id":"mode.auto","display":{"title":"Auto"}},
              {"id":"custom.saved","title":"Saved","display":null,"disabled":null},
              {"id":"model.disabled","disabled":true},
              {"id":"   "}
            ]}}}}
            """#)])
            let values = try await TodayProvider.fetchModels(sessionCookie: "YWJjZA==")
            try expect(values.map { $0.id } == ["mode.auto", "custom.saved"], "model IDs filtered or rewritten")
            try expect(values.map { $0.displayName } == ["Auto", "Saved"], "model titles")
            try expect(values.allSatisfy { $0.provider == "Today AI" }, "wrong provider")
        }
        await suite.run("real complete sends canonical context and returns only current origin") {
            var sentID = ""
            FixtureURLProtocol.install([
                tokenStep,
                Step("PUT", "/api/cloud/v1/pricing/model-option") { request in
                    let json = try body(request)
                    try expect(json["optionId"] as? String == "mode.auto", "mode selection changed")
                    return "{}"
                },
                Step("POST", "/api/cloud/v1/messages", reply: { request in
                    let json = try body(request)
                    sentID = json["clientMessageId"] as? String ?? ""
                    try expect(UUID(uuidString: sentID) != nil, "clientMessageId must be a fresh UUID")
                    let parts = (json["body"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                    try expect(parts.first?["text"] as? String == "[system]\nsys\n\n[user]\nfirst\n\n[assistant]\nprevious\n\n[user]\nnext", "real request dropped caller context")
                    try expect(parts.first?["type"] as? String == "text" && json["isMainChat"] as? Bool == true, "real request is not canonical")
                    try expect(request.value(forHTTPHeaderField: "Origin") == "https://todayai.cn", "Origin header")
                    try expect(request.value(forHTTPHeaderField: "Referer") == "https://todayai.cn/", "Referer header")
                    return "{\"data\":{\"canonicalMessage\":{\"clientMessageId\":\"\(sentID)\",\"conversationId\":\"main\"}}}"
                }),
                Step("GET", "/api/cloud/v1/conversations/messages", reply: { request in
                    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    try expect(items.contains(URLQueryItem(name: "isMainChat", value: "true")), "main chat query")
                    try expect(items.contains(URLQueryItem(name: "limit", value: "100")), "poll limit")
                    try expect(!items.contains { $0.name == "conversationId" }, "must not send main as conversationId")
                    try expect(!sentID.isEmpty, "poll preceded send")
                    return history.replacingOccurrences(of: "CURRENT", with: sentID)
                })
            ])
            let provider = TodayProvider(sessionCookie: "YWJjZA==", model: .init(id: "mode.auto", displayName: "Auto", provider: "Today AI"))
            let value = try await provider.sendMessage(messages: [
                .init(role: .user, content: "first"), .init(role: .assistant, content: "previous"),
                .init(role: .user, content: "next")
            ], systemPrompt: "sys", maxTokens: 32, temperature: nil)
            try expect(value.text == "correct answer" && value.stopReason == "stop", "stale assistant or unknown part leaked")
        }
        await suite.run("wrong echoed clientMessageId fails before polling") {
            FixtureURLProtocol.install([tokenStep,
                Step("PUT", "/api/cloud/v1/pricing/model-option"),
                Step("POST", "/api/cloud/v1/messages", #"{"data":{"clientMessageId":"different-turn"}}"#)
            ])
            let client = TodayClient(sessionCookie: "YWJjZA==")
            do {
                _ = try await client.complete(messages: [.init(role: .user, content: "hello")], systemPrompt: nil, modelID: "mode.auto")
                throw FixtureFailure("mismatched echoed ID accepted")
            } catch TodayProviderError.invalidResponse(let detail) {
                try expect(detail.contains("clientMessageId"), "wrong validation failure")
            }
        }
        await suite.run("401 refresh decodes nested token and retries exactly once") {
            FixtureURLProtocol.install([tokenStep,
                Step("PUT", "/api/cloud/v1/pricing/model-option", "{}", status: 401),
                Step("POST", "/api/token", #"{"data":{"token":"refreshed","expiresIn":3600}}"#),
                Step("PUT", "/api/cloud/v1/pricing/model-option") { request in
                    try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed", "retry reused expired token")
                    let json = try body(request)
                    try expect(json["optionId"] as? String == "custom.retry", "retry changed model option")
                    return "{}"
                }
            ])
            let client = TodayClient(sessionCookie: "YWJjZA==")
            try await client.fixtureSelect("custom.retry")
        }
        print("TODAY_FIXTURES passed=\(suite.passed) failed=\(suite.failed)")
        exit(suite.failed == 0 && suite.passed == 18 ? 0 : 1)
    }
}
'''


if __name__ == '__main__':
    sys.exit(main())
