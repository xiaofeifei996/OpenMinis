"""Compile unchanged production probe bodies with deterministic streaming fakes.

Unlike the scheduler harness's fixed-result producer, this tests the real plain
and agent-fallback measurements, including provider creation and empty deltas.
The streams deliberately never send EOF: the first text must finish the test.
"""
import subprocess
from pathlib import Path


def run_probe_clock_test(source, harness, tmp):
    start = source.index('    private func performLatencyProbe(')
    end = source.index('    /// All callers share one scheduler', start)
    actual = source[start:end]
    start = harness.index('    private func performLatencyProbe(')
    end = harness.index('    private func readLatencyCache()', start)
    program = harness[:start] + actual + harness[end:]
    program = program.replace('struct TestLog { func info(_ text: String) {} }',
                              'struct TestLog { func info(_ text: String) {}\n'
                              'func warning(_ text: String) {} }')
    today = (Path(__file__).resolve().parents[1] / 'src/ios/Providers/TodayProvider.swift').read_text()
    errors = today[today.index('private enum TodayProviderError:'):today.index('/// Covers ALL Today clients')]
    classifiers = today[today.index('    static func generationMayHaveBeenSubmitted('):today.index('    /// Account-scoped model discovery')]
    program += errors + '\nenum TodayProvider {\n' + classifiers + '\n}\n'
    program += r'''
enum Role { case user }
struct LLMMessage { let role: Role; let content: String }
enum LLMStreamChunk: Sendable { case text(String) }
enum AgentPart { case text(String) }
struct AgentMessage { let role: Role; let parts: [AgentPart] }
enum AgentEvent: Sendable { case textDelta(String) }
enum Thinking { case off }
enum OpenCodeChannel { static func oneOffSessionId() -> String { "clock-test" } }
struct EnvelopeError: LocalizedError { var errorDescription: String? { "unsupported envelope" } }
@MainActor enum ProbeNetwork {
    static var failPlain = false
    static var plainError: Error = EnvelopeError()
    static var agentCalls = 0
    static var tokenAt: Date?
    static func stream<T: Sendable>(_ empty: T, _ token: T) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                continuation.yield(empty)
                try? await Task.sleep(nanoseconds: 100_000_000)
                tokenAt = Date()
                continuation.yield(token)
                // No EOF: production must return on the first nonempty text.
            }
        }
    }
}
@MainActor struct PlainProvider {
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        if ProbeNetwork.failPlain {
            try await Task.sleep(nanoseconds: 80_000_000)
            throw ProbeNetwork.plainError
        }
        return ProbeNetwork.stream(.text(""), .text("hi"))
    }
}
@MainActor enum LLMProviderFactory {
    static func makeProvider(for entry: ModelEntry, sessionId: String?) async throws -> PlainProvider {
        try await Task.sleep(nanoseconds: 50_000_000)
        return PlainProvider()
    }
}
@MainActor struct AgentProvider {
    func streamAgentMessageClamped(messages: [AgentMessage], systemPrompt: String?, tools: [String],
                                  maxTokens: Int, thinkingLevel: Thinking) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        ProbeNetwork.agentCalls += 1
        return ProbeNetwork.stream(.textDelta(""), .textDelta("hi"))
    }
}
@MainActor enum AIChatViewModel {
    static func makeAgentProvider(for entry: ModelEntry, sessionId: String?) async -> AgentProvider {
        try? await Task.sleep(nanoseconds: 50_000_000)
        return AgentProvider()
    }
}
@main struct ProbeClockRegression {
    @MainActor static func main() async throws {
        for fallback in [false, true] {
            ProbeNetwork.failPlain = fallback
            ProbeNetwork.agentCalls = 0
            ProbeNetwork.tokenAt = nil
            let optimizer = ChatOptimizer()
            optimizer.catalog = [ModelEntry(id: "clock", providerInstanceId: "A")]
            let leaf = optimizer.latencyState.entry(id: "clock")
            var startedAt: Date?
            let subscription = leaf.$result.sink { result in
                if result.phase == .running { startedAt = Date() }
            }
            let begin = Date()
            await optimizer.speedTestAll(sessionId: nil, perEntryTimeout: 2, includeAllAccounts: true)
            let measured = leaf.result.seconds!
            let tokenElapsed = ProbeNetwork.tokenAt!.timeIntervalSince(startedAt!)
            assert(leaf.result.phase == .finished && leaf.result.error == nil)
            assert(abs(measured - tokenElapsed) < 0.05)
            assert(measured >= (fallback ? 0.35 : 0.24))
            assert(Date().timeIntervalSince(begin) < 1.5)
            assert(ProbeNetwork.agentCalls == (fallback ? 1 : 0))
            assert(leaf.result.seconds == measured)
            withExtendedLifetime(subscription) {}
            print("PASS: unchanged production \(fallback ? "fallback" : "plain") probe starts at dispatch, includes setup/empty deltas, returns at first text without EOF (\(measured)s)")
        }
        let cases: [(Bool, Error, Bool, Bool)] = [
            (false, URLError(.timedOut), true, true),
            (true, EnvelopeError(), false, true),
            (true, TodayProviderError.generationSubmitted(TodayProviderError.http(429, "rate limited")), false, false),
            (true, TodayProviderError.generationSubmitted(TodayProviderError.timeout), true, false)
        ]
        for (today, error, timedOut, retryAllowed) in cases {
            ProbeNetwork.failPlain = true
            ProbeNetwork.plainError = error
            ProbeNetwork.agentCalls = 0
            let optimizer = ChatOptimizer()
            if today { optimizer.store.todayAccounts = ["A"] }
            let entry = ModelEntry(id: "no-replay", providerInstanceId: "A")
            let result = await optimizer.measureLatency(entry: entry, sessionId: nil, timeout: 2)
            assert(result.seconds == nil && result.isTimeout == timedOut)
            assert(result.retryAllowed == retryAllowed && ProbeNetwork.agentCalls == 0)
        }
        print("PASS: unchanged production probe and Today classifiers distinguish timeouts/submitted 429s without agent replay")
    }
}
'''
    swift = tmp / 'ProbeClockRegression.swift'
    binary = tmp / 'probe-clock-regression'
    swift.write_text(program)
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(swift), '-o', str(binary)],
                   check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=15)
