"""Test the production stream-open gate/watchdog without UIKit.

Run: python3 scripts/test_model_wait.py (requires swiftc on PATH).
--static-only checks wiring when an iOS/Linux Swift toolchain is unavailable.
The opener deliberately ignores cancellation until the test releases it;
returning from timeout/cancel BEFORE that release proves there is no task join.
"""
from pathlib import Path
import argparse
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CHAT = ROOT / 'src/ios/Agent/Chat'
fallback = (CHAT / 'AIChatViewModel+Fallback.swift').read_text()
sse = (CHAT / 'AIChatViewModel+SSEStream.swift').read_text()


def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


gate = between(fallback, '// BEGIN StreamOpenDeadline', '// END StreamOpenDeadline')
watchdog = 'private final class StreamStallWatchdog' + between(
    sse, 'private final class StreamStallWatchdog', '// MARK: - Background SSE Stream Processing')
progress = '    nonisolated static func isModelProgress' + between(
    sse, '    nonisolated static func isModelProgress', '    // MARK: - Background SSE Stream Processing')
cancellation = 'private func checkStreamCancellation' + between(
    fallback, 'private func checkStreamCancellation', '// MARK: - Auto-Retry + Group-Level Fallback')
errors = (ROOT / 'src/ios/Providers/LLMError.swift').read_text()

# Assert callers use the tested code, not an unbounded bypass.
assert fallback.count('provider.streamAgentMessage(') == 1
assert 'currentProvider.streamAgentMessage(' not in fallback
assert fallback.count('let stream = try await openAgentStream(') == 2
assert 'let timeout = provider.responseIdleTimeout' in fallback
assert 'withThrowingTaskGroup' not in gate
assert 'modelWaitStartedAt = Date()' in fallback
assert 'modelWaitPhase = "正在连接模型"' in fallback
assert 'modelWaitPhase = "等待模型返回内容"' in fallback
assert 'modelWaitStartedAt = nil' not in fallback
assert 'for attempt in 0...retryDelays.count {\n            try Task.checkCancellation()' in fallback
assert fallback.count('while true {\n            try Task.checkCancellation()') == 2
assert fallback.count('try checkStreamCancellation(error)') == 5
fire = sse.index('guard stallWatchdog.fire(')
assert fire < sse.index('let appState = await MainActor.run', fire)
assert 'ifWaitingSince: waitStart' in sse
assert 'if event.map({ Self.isModelProgress($0) }) ?? true' in sse
print('PASS: production wiring, cancellation guards and progress/deadline ordering')

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--static-only', action='store_true')
args = parser.parse_args()
if args.static_only:
    print('SKIP: Swift runtime tests (--static-only)')
    raise SystemExit(0)
if not shutil.which('swiftc'):
    raise SystemExit('swiftc unavailable; runtime tests NOT run. Use --static-only for wiring checks.')

program = 'import Foundation\n' + gate + watchdog + errors + cancellation + r'''
// Only event payload types are stubbed; progress predicate and concurrency code
// above are extracted verbatim from production.
enum AgentStreamEvent {
    case usage, responseModel(String), textDelta(String), thinkingDelta(String)
    case reasoningContent(String), toolInputDelta(String, String)
    case contentBlockStart, toolCallComplete, reasoningEcho, streamActivity, done
}
enum Progress {
''' + progress + r'''
}
enum TestError: Error { case timeout, provider }

// Checked continuations intentionally do not observe task cancellation.
actor Latch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        await withCheckedContinuation { c in
            if released { c.resume() } else { continuation = c }
        }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
actor Counter {
    var count = 0
    func increment() { count += 1 }
}
func expectCancellation(_ task: Task<Int, Error>) async {
    do { _ = try await task.value; fatalError("cancel returned success") }
    catch is CancellationError {}
    catch { fatalError("wrong cancellation: \(error)") }
}

@main struct Tests {
    static func main() async throws {
        // Timeout returns while the provider is still suspended; late success
        // is released afterward, never delivered as another consumer result.
        let entered = Latch(), release = Latch(), returned = Latch()
        let task = Task {
            try await StreamOpenGate<Int>.open(timeout: 0.02, timeoutError: TestError.timeout) {
                await entered.release()
                await release.wait()
                await returned.release()
                return 17
            }
        }
        // Do not wait for `entered`: on a loaded runner the deadline may win
        // even before the opener is scheduled. Release only AFTER the timeout
        // returns, so any opener that did start necessarily ignored cancellation.
        do { _ = try await task.value; fatalError("timeout returned success") }
        catch TestError.timeout {}
        await release.release()
        let timedOutGate = StreamOpenGate<Int>()
        precondition(timedOutGate.finish(.failure(TestError.timeout)))
        precondition(!timedOutGate.finish(.success(17)))
        do {
            let _: Int = try await withCheckedThrowingContinuation { timedOutGate.register($0) }
            fatalError("late success replaced timeout")
        } catch TestError.timeout {}
        print("PASS: noncooperative open deadline and deterministic late-success rejection")

        let stalledGate = StreamOpenGate<Int>()
        let stalledEntered = Latch(), stalledRelease = Latch(), lateReturned = Latch()
        let stalledConsumer = Task {
            try await withCheckedThrowingContinuation { c in
                stalledGate.register(c)
                stalledGate.launch {
                    await stalledEntered.release()
                    await stalledRelease.wait()
                    precondition(!stalledGate.finish(.success(88)))
                    await lateReturned.release()
                }
            }
        }
        await stalledEntered.wait()
        precondition(stalledGate.finish(.failure(TestError.timeout)))
        do { _ = try await stalledConsumer.value; fatalError("late stream escaped") }
        catch TestError.timeout {}
        await stalledRelease.release()
        await lateReturned.wait()
        print("PASS: forced timeout resumes before already-started opener, late value discarded")

        let entered2 = Latch(), release2 = Latch(), returned2 = Latch()
        let cancelled = Task {
            try await StreamOpenGate<Int>.open(timeout: 3600, timeoutError: TestError.timeout) {
                await entered2.release()
                await release2.wait()
                await returned2.release()
                return 29
            }
        }
        await entered2.wait()
        cancelled.cancel()
        await expectCancellation(cancelled)
        await release2.release()
        await returned2.wait()
        print("PASS: cancellation returns before noncooperative opener exits")

        // Force cancellation BEFORE registration and launch, without relying
        // on scheduler timing. It must neither hang nor invoke the operation.
        let earlyGate = StreamOpenGate<Int>()
        precondition(earlyGate.finish(.failure(CancellationError())))
        let counter = Counter()
        earlyGate.launch { await counter.increment() }
        do {
            let _: Int = try await withCheckedThrowingContinuation { earlyGate.register($0) }
            fatalError("early cancellation lost")
        } catch is CancellationError {}
        precondition(!earlyGate.finish(.success(99)))
        let count = await counter.count
        precondition(count == 0)
        print("PASS: cancellation before registration; late completion loses")

        let ready = Latch(), unblock = Latch()
        let alreadyCancelled = Task {
            await ready.release()
            await unblock.wait()
            return try await StreamOpenGate<Int>.open(timeout: 1, timeoutError: TestError.timeout) {
                await counter.increment()
                return 9
            }
        }
        await ready.wait()
        alreadyCancelled.cancel()
        await unblock.release()
        await expectCancellation(alreadyCancelled)
        let calls = await counter.count
        precondition(calls == 0)
        let success = try await StreamOpenGate<Int>.open(timeout: 1, timeoutError: TestError.timeout) { 42 }
        precondition(success == 42)
        do {
            let _: Int = try await StreamOpenGate<Int>.open(timeout: 1, timeoutError: TestError.timeout) {
                throw TestError.provider
            }
            fatalError("provider error swallowed")
        } catch TestError.provider {}
        print("PASS: pre-cancelled request, normal success and provider failure")

        // Single-resume competition is deterministic about the invariant, not
        // about which contender wins. Every continuation is resumed exactly once.
        for _ in 0..<100 {
            let race = StreamOpenGate<Int>()
            let value: Int = try await withCheckedThrowingContinuation { c in
                race.register(c)
                for n in 0..<8 { race.launch { race.finish(.success(n)) } }
            }
            precondition((0..<8).contains(value))
            precondition(!race.finish(.success(100)))
        }
        print("PASS: 100 concurrent single-resume races")

        // Stale watchdog snapshots must fail both during event processing and
        // after a later wait has started. Metadata must retain the same deadline.
        let watchdog = StreamStallWatchdog()
        let first = Date(timeIntervalSince1970: 100)
        let second = Date(timeIntervalSince1970: 200)
        watchdog.beginWait(at: first)
        watchdog.endWait()
        precondition(!watchdog.fire(TestError.timeout, ifWaitingSince: first))
        watchdog.beginWait(at: second)
        precondition(!watchdog.fire(TestError.timeout, ifWaitingSince: first))
        watchdog.beginWait(at: second.addingTimeInterval(10))
        precondition(watchdog.waitStart == second)
        precondition(watchdog.fire(TestError.timeout, ifWaitingSince: second))
        do { try await watchdog.wait(); fatalError("watchdog failed to throw") }
        catch TestError.timeout {}
        for event in [AgentStreamEvent.usage, .responseModel("model"), .textDelta(""), .thinkingDelta("")] {
            precondition(!Progress.isModelProgress(event))
        }
        for event in [AgentStreamEvent.streamActivity, .reasoningEcho, .reasoningContent("hidden"), .thinkingDelta("think"), .textDelta("text"), .toolCallComplete] {
            precondition(Progress.isModelProgress(event))
        }
        print("PASS: stale watchdog rejection, metadata and hidden reasoning")

        let cancellations: [Error] = [CancellationError(), LLMError.cancelled,
                                     URLError(.cancelled), LLMError.networkError(underlying: URLError(.cancelled)),
                                     LLMError.unknown(underlying: CancellationError())]
        for error in cancellations {
            do { try checkStreamCancellation(error); fatalError("cancel was retryable") }
            catch is CancellationError {}
        }
        try checkStreamCancellation(LLMError.transientError(message: "timeout"))
        print("PASS: cancellation classification bypasses all fallback strategies")
    }
}
'''
with tempfile.TemporaryDirectory() as tmp:
    source = Path(tmp) / 'ModelWaitTests.swift'
    source.write_text(program)
    binary = Path(tmp) / 'model-wait-tests'
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(source), '-o', str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=15)
