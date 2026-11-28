"""Compile unchanged production probe bodies with deterministic streaming fakes.

Unlike the scheduler harness's fixed-result producer, this tests the real plain
and agent-fallback measurements, including provider creation and empty deltas.
The streams deliberately never send EOF: the first text must finish the test.
"""
import argparse
import shutil
import subprocess
from pathlib import Path


def production_probes(source):
    start = source.index('    private func performLatencyProbe(')
    end = source.index('    /// All callers share one scheduler', start)
    return source[start:end]


def check_probe_contract(source):
    actual = production_probes(source)
    plain = actual[:actual.index('    private func probeViaAgentPath(')]
    compact = ''.join(plain.split())
    checks = {
        'plain timeout classification is exclusively URLError.timedOut':
            'lettimedOut=(erroras?URLError)?.code==.timedOutletfailure=' in compact,
        'generic failures retain the default retry contract':
            'letfailure=LatencyProbe(seconds:nil,error:timedOut?"first-tokentimeout":msg)' in compact,
        'timeouts and throttles return before agent fallback':
            0 <= plain.find('if Self.isThrottle(failure) { return failure }')
            < plain.find('if timedOut { return failure }')
            < plain.find('await probeViaAgentPath('),
        'plain and agent paths measure from dispatch and ignore empty deltas':
            actual.count('Date().timeIntervalSince(start)') == 2
            and 'if case .text(let t) = chunk, !t.isEmpty {' in plain
            and 'if case .textDelta(let t) = event, !t.isEmpty {' in actual,
        'agent fallback preserves URL timeout and HTTP 429 handling':
            'if (error as? URLError)?.code == .timedOut {' in actual
            and 'return Self.isThrottle(failure) ? failure : nil' in actual,
    }
    for name, passed in checks.items():
        print(('PASS' if passed else 'FAIL') + ': ' + name, flush=True)
    assert all(checks.values())


def run_probe_clock_test(source, harness, tmp):
    actual = production_probes(source)
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
struct EnvelopeError: LocalizedError { var errorDescription: String? { "400 param model unsupport" } }
struct RateLimitError: LocalizedError { var errorDescription: String? { "HTTP 429 rate limited" } }
struct TimeoutTextError: LocalizedError { var errorDescription: String? { "request timeout" } }
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
        let cases: [(Error, Bool, String)] = [
            (URLError(.timedOut), true, "first-token timeout"),
            (RateLimitError(), false, "HTTP 429 rate limited"),
            (CancellationError(), false, "cancelled")
        ]
        for (error, timedOut, message) in cases {
            ProbeNetwork.failPlain = true
            ProbeNetwork.plainError = error
            ProbeNetwork.agentCalls = 0
            let optimizer = ChatOptimizer()
            let entry = ModelEntry(id: "no-replay", providerInstanceId: "A")
            let result = await optimizer.measureLatency(entry: entry, sessionId: nil, timeout: 2)
            assert(result.seconds == nil && result.isTimeout == timedOut)
            assert(result.error == message)
            assert(result.retryAllowed && ProbeNetwork.agentCalls == 0)
        }
        print("PASS: production probe uses generic URL timeout, HTTP 429 and cancellation failures without agent replay; default retry contract remains")

        // An error mentioning timeout is not a URL timeout; like the Raccoon
        // envelope mismatch, it must still be eligible for the agent path.
        let recoveryErrors: [Error] = [EnvelopeError(), TimeoutTextError()]
        for error in recoveryErrors {
            ProbeNetwork.failPlain = true
            ProbeNetwork.plainError = error
            ProbeNetwork.agentCalls = 0
            let optimizer = ChatOptimizer()
            let result = await optimizer.measureLatency(
                entry: ModelEntry(id: "agent-recovery", providerInstanceId: "A"), sessionId: nil, timeout: 2)
            assert(result.seconds != nil && result.error == nil && !result.isTimeout)
            assert(result.retryAllowed && ProbeNetwork.agentCalls == 1)
        }
        print("PASS: Raccoon-style envelope mismatch and arbitrary timeout text retain generic agent recovery")
    }
}
'''
    swift = tmp / 'ProbeClockRegression.swift'
    binary = tmp / 'probe-clock-regression'
    swift.write_text(program)
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(swift), '-o', str(binary)],
                   check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--static-only', action='store_true',
                        help='check production probe contracts without compiling Swift')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = (root / 'src/ios/Agent/Chat/ChatOptimizer.swift').read_text()
    check_probe_contract(source)
    if args.static_only or not shutil.which('swiftc'):
        print('SKIP: Swift probe runtime (static-only requested or swiftc unavailable)')
    else:
        # The parent harness supplies the extracted cache/policy/scheduler types
        # and invokes run_probe_clock_test; this module does not duplicate them.
        subprocess.run(['python3', str(root / 'scripts/test_speedtest_regression.py')], check=True)
