"""Compile unchanged production probe bodies with deterministic streaming fakes.

Unlike the scheduler harness's fixed-result producer, this tests the real plain
and agent-fallback measurements, including provider creation and empty deltas.
The streams deliberately never send EOF: the first text must finish the test.
"""
import subprocess


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
            throw EnvelopeError()
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
                if case .running(let start) = result.phase { startedAt = start }
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
            assert(leaf.result.elapsed(at: Date().addingTimeInterval(100)) == measured)
            withExtendedLifetime(subscription) {}
            print("PASS: unchanged production \(fallback ? "fallback" : "plain") probe shares dispatched clock, includes setup/empty deltas, freezes at first text without EOF (\(measured)s)")
        }
    }
}
'''
    swift = tmp / 'ProbeClockRegression.swift'
    binary = tmp / 'probe-clock-regression'
    swift.write_text(program)
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(swift), '-o', str(binary)],
                   check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=15)
