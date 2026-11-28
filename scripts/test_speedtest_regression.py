#!/usr/bin/env python3
"""Regression-test the production speed-test scheduler/deadline (no network).

Linux: --static-only. macOS CI: compiles extracted, unmodified Swift methods
against a fake provider/catalog. This is not a Python reimplementation of the
scheduler. UIKit geometry still requires device/UI validation.
"""
from pathlib import Path
import argparse
import json
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'src/ios/Agent/Chat/ChatOptimizer.swift').read_text()
picker = (ROOT / 'src/ios/Views/Providers/UnifiedModelPicker.swift').read_text()
today = (ROOT / 'src/ios/Providers/TodayProvider.swift').read_text()
quick = (ROOT / 'src/ios/Views/Providers/ModelQuickTestSheet.swift').read_text()


def section(start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


strings = json.loads((ROOT / 'src/ios/SpeedTest.xcstrings').read_text())['strings']
quick_success = section('    func recordSuccessfulTextQuickTest(', '    /// Measure response latency')
instance_progress = section('struct InstanceSpeedTestProgress:', '@MainActor\nfinal class ModelSpeedTestStatus')
instance_button = picker[picker.index('    private struct InstanceSpeedTestButton: View'):]
instance_button = instance_button[:instance_button.index('    private func isEntryUnavailable(')]
checks = {
    'per-instance position counts reached rows while preserving completed work':
        'var reached: Int = 0' in instance_progress
        and 'min(total,max(done,reached))' in ''.join(instance_progress.split()),
    'API button displays reached position, but spinner still follows completion':
        r'Text("\(joined.displayedPosition)/\(joined.total)")' in instance_button
        and 'if joined.done < joined.total || joined.total == 0 {' in instance_button
        and r'Text("\(joined.done)/\(joined.total)")' not in instance_button,
    'Quick Test writes completed latency live for all providers':
        'let measuredElapsed = elapsed.map { $0.isFinite && $0 > 0 } == true' in quick_success
        and 'latencyState.cache.entries[id] = elapsed' in quick_success
        and 'Any successful Quick Test duration is immediately' in quick
        and 'Self.latencySecondsKey' in quick_success
        and 'if !speedTestStatus.running { writeLatencyCache(readLatencyCache()) }' in quick_success,
    'new timeout, latency and rate-limit labels have English and both Chinese translations':
        all(strings.get(key, {}).get('localizations', {}).get(locale, {}).get('stringUnit', {}).get('value')
            for key in ['Timed out', 'Speed test timed out; model availability is unknown', 'Response latency: %@',
                        'Rate limited', 'Rate limited; last successful latency: %@']
            for locale in ['en', 'zh-Hans', 'zh-Hant']),
    'throttle never presents a cached latency as a fresh success':
        'latencyState.cache.errors[id] = throttleMessage' in source
        and 'latencyState.cache.errors[entry.id] = "Rate limited"' in source
        and 'if isRateLimited {' in picker
        and picker.index('if isRateLimited {') < picker.index('} else if let text {')
        and 'Rate limited; last successful latency: ' in picker
        and 'latencyState.enqueue(id: id, error: error)' in source,
    'no real-time numeric stopwatch in the picker':
        'TimelineView(' not in picker and 'func elapsed(' not in source
        and 'case running(startedAt:' not in source,
    'both real API and group row paths mount the badge':
        'LatencyBadgeCell(entryId: entry.id, source: "group")' in picker
        and 'LatencyBadgeCell(entryId: entry.id)' in picker,
    'real app diagnostics cover probe/group/publisher/badge and main actor':
        all('"' + event + '"' in source + picker for event in
            ['first-token', 'probe-finish', 'group-next', 'publish', 'badge-body', 'badge-mounted', 'main-actor-lag'])
        and 'events.count >= 6000' in source,
    'diagnostics are exportable without per-completion disk writes':
        'exportSpeedTestDiagnostics()' in picker and 'ModelLatencyDiagnostics.encode(snapshot)' in picker,
    'diagnostics distinguish queue waits, probe timeout policy and account cooldown':
        all('"' + event + '"' in source for event in
            ['scheduler-policy', 'enqueue', 'account-cooldown', 'account-exhausted'])
        and 'delayMs: throttleCooldown * 1000' in source,
    'default bounded parallelism and provider-specific per-account cap':
        'concurrency: Int = 6' in source
        and 'var accountLimit: Int { 1 }' in source
        and 'count < policy.accountLimit' in source
        and 'min(self.latencyPolicy(for: entry).accountLimit, globalLimit)' in source
        and 'let globalLimit = min(6, max(1, concurrency))' in source
        and 'source: "global:\\(globalLimit),account:1,today:1"' in source,
    'Today completion budget is derived from real poll and HTTP budgets only':
        'var timeout: TimeInterval { isToday ? TodayCompletionPolicy.latencyProbeTimeout : 12 }' in source
        and 'let deadline = timeout ?? policy.timeout' in source
        and 'latencyProbeTimeout = pollingTimeout + 4 * requestTimeout' in today
        and 'addingTimeInterval(TodayCompletionPolicy.pollingTimeout)' in today
        and today.count('request.timeoutInterval = TodayCompletionPolicy.requestTimeout') == 2,
    'Today never falls through to a second paid agent envelope':
        'if latencyPolicy(for: entry).isToday || timedOut { return failure }' in source
        and quick.index('?.providerType == .today') < quick.index('responseText = try await performAgentTextProbe'),
    'submitted Today throttle cannot retry a generation; safe account cooldown remains':
        'retryAllowed: !TodayProvider.generationMayHaveBeenSubmitted(error)' in source
        and 'if probe.retryAllowed, !exhaustedAccounts.contains(providerId)' in source
        and 'queue.insert(original, at: 0)' in source
        and today.index('submitted = true') < today.index('let sent: TodaySendResponse')
        and 'guard !(method == "POST" && path == "/v1/messages")' in today,
    'Today client gate covers selection, POST, poll and cancellation across clients':
        today.index('TodayAccountGate.shared.acquire(sessionCookie)') < today.index('try await selectModel(modelID)')
        and today.count('await TodayAccountGate.shared.release(sessionCookie)') == 2
        and 'Task { await self.cancel(account, id: id) }' in today,
    'timeout is not a red failure, including legacy cached timeouts':
        'else if state.result.isTimeout' in picker
        and picker.index('else if state.result.isTimeout') < picker.index('} else if failed {')
        and 'error == "first-token timeout"' in source
        and 'Speed test timed out; model availability is unknown' in picker,
    'only nonempty text Quick Tests clear errors; measured duration writes for all providers':
        'if case .text(let text) = state, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty' in quick
        and 'let measuredElapsed = elapsed.map { $0.isFinite && $0 > 0 } == true' in quick_success
        and 'latencyState.cache.entries[id] = elapsed' in quick_success
        and 'Any successful Quick Test duration is immediately' in quick
        and 'recordSuccessfulTextQuickTest(\n                            entry: entry, elapsed: run.elapsed)' in quick
        and 'func recordSuccessfulTextQuickTest(entry: ModelEntry, elapsed: TimeInterval? = nil)' in source
        and 'validationAtStart[id] == textValidationRevisions[id, default: 0]' in source,
    'task-group scheduler helpers explicitly retain main-actor isolation':
        'withTaskGroup(of: (String, String, LatencyProbe).self) { @MainActor group in' in source
        and '@MainActor func nextReady()' in source and '@MainActor func pump()' in source,
    'no serial rendering sleep': '50_000_000' not in source and 'concurrency: 1,' not in picker,
    'single process-wide run with explicit scoped queue merge':
        'speedTestWaiters.append($0)' in source and 'requestedInstanceIds.contains($0.providerInstanceId)' in source,
    'real deadline spans the probe, not a structured task-group join':
        'race.timer = Task' in source and 'race.request = Task' in source
        and 'timeout: perEntryTimeout' in source
        and 'withTaskGroup' not in section('    func measureLatency(', '    private func performLatencyProbe('),
    'uncooperative producers retain their permits':
        'activeLatencyProbes.merging(scheduled)' in source
        and 'defer { self.activeLatencyProbes.removeValue(forKey: entry.id) }' in source,
    'late results have a single winner': 'guard !finished else { return }' in source,
    'throttles bypass agent retry': 'if Self.isThrottle(failure) { return failure }' in source,
    'hard failures invalidate stale latency but stay soft':
        'latencyState.cache.entries.removeValue(forKey: id)' in source and 'latencyState.cache.unavailable.append' not in source,
    'badge leaf observes a stable per-entry publisher':
        '@ObservedObject private var state: ModelLatencyEntryState' in picker
        and 'optimizer.latencyState.entry(id: entryId)' in picker
        and '@Published var cache' not in source,
    'no local reference-state or disk adoption bridge':
        '@State private var badges' not in picker and 'currentLatencyBadges' not in picker,
    'empty badge is a real fixed-width layout child':
        'ZStack(alignment: .trailing) {\n                Color.clear' in picker
        and '.frame(width: 48, height: 18, alignment: .trailing)' in picker,
    'quick test has a fixed external slot':
        '.frame(width: 32, height: 32) // keep the control column' in picker,
    'background cleanup cannot overwrite an active snapshot':
        'guard !speedTestStatus.running else { return }' in source,
    'skipped rows finish per-instance progress without invented model errors':
        'for entry in queue {\n                markReached(entry)\n                complete(entry.providerInstanceId, skipped: true)\n            }' in source,
    'header button invokes scoped entry point, not global':
        'InstanceSpeedTestButton(instanceId: item.instance.id' in picker
        and 'ChatOptimizer.shared.speedTestInstance(' in picker,
    'partial automatic API scope stays upgradeable; explicit full scope locks before suspension':
        'let isDisabled = joined != nil && (status.includesAllAccounts || status.fullInstanceIds.contains(instanceId))' in picker
        and '@Published var fullInstanceIds: Set<String> = []' in source
        and 'speedTestStatus.fullInstanceIds = []' in source
        and source.index('speedTestStatus.fullInstanceIds.insert(instanceId)')
            < source.index('await withCheckedContinuation { speedTestWaiters.append($0) }'),
}
for name, passed in checks.items():
    print(('PASS' if passed else 'FAIL') + ': ' + name, flush=True)
assert all(checks.values())

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--static-only', action='store_true')
args = parser.parse_args()
if args.static_only:
    print('SKIP: Swift runtime and SwiftUI/device geometry (Linux has no swiftc/Xcode)')
    raise SystemExit(0)
if not shutil.which('swiftc'):
    raise SystemExit('swiftc unavailable: runtime tests NOT run; use --static-only on Linux')

types = section('struct ModelLatencyCache:', '/// Errors surfaced by `ChatOptimizer`.')
fields = section('    let latencyState: ModelLatencyState', '    private init()')
cache = section('    private func readLatencyCache()', '    /// All entries that are usable:')
probe = section('    private func latencyPolicy(', '    private func performLatencyProbe(')
today_policy = 'enum TodayCompletionPolicy {' + today.split('enum TodayCompletionPolicy {', 1)[1].split('\n}', 1)[0] + '\n}\n'
scheduler = section('    func speedTestInstance(', '    /// Compatibility signal')
notifications = section('    static let latencyUpdatedNotification', '    /// Whether a probe failure means')
throttle = section('    private static func isThrottle(', '    /// The fastest available entry per the latency cache')

program = 'import Foundation\nimport Combine\n' + today_policy + types + r'''
enum ProviderType { case today, other }
struct Instance { let providerType: ProviderType }
@MainActor final class TestStore {
    var todayAccounts: Set<String> = []
    func instance(for id: String) -> Instance? {
        Instance(providerType: todayAccounts.contains(id) ? .today : .other)
    }
}
struct ModelEntry: Sendable { let id: String; let providerInstanceId: String }
enum ChatOptimizerSettings { static let latencyCacheKey = "speedtest-regression" }
struct TestLog { func info(_ text: String) {} }
@MainActor final class ChatOptimizer {
''' + fields + r'''
    let userDefaults = UserDefaults(suiteName: UUID().uuidString)!
    let logger = TestLog()
    let store = TestStore()
    var noRetry: Set<String> = []
    var maxByAccount: [String: Int] = [:]
    var automatic: [ModelEntry] = []
    var catalog: [ModelEntry] = []
    var failures: [String: String] = [:]
    var delays: [String: UInt64] = [:]
    var holdRequests = false
    var held: [String: CheckedContinuation<Void, Never>] = [:]
    var starts: [String: Int] = [:]
    var launchAccounts: [String] = []
    var realActive = 0
    var activeByAccount: [String: Int] = [:]
    var maxActive = 0
    var maxAccount = 0
    var activeCount: Int { activeLatencyProbes.count }
    init() { latencyState = ModelLatencyState(cache: ModelLatencyCache()) }
    func availableEntries() -> [ModelEntry] { automatic }
    func allEntriesAcrossAccounts() -> [ModelEntry] { catalog }
    func releaseHeld() {
        let pending = held
        held.removeAll()
        for continuation in pending.values { continuation.resume() }
    }
    private func performLatencyProbe(entry: ModelEntry, sessionId: String?, startedAt: Date) async -> LatencyProbe {
        starts[entry.id, default: 0] += 1
        launchAccounts.append(entry.providerInstanceId)
        realActive += 1
        activeByAccount[entry.providerInstanceId, default: 0] += 1
        maxActive = max(maxActive, realActive)
        maxAccount = max(maxAccount, activeByAccount[entry.providerInstanceId, default: 0])
        maxByAccount[entry.providerInstanceId] = max(maxByAccount[entry.providerInstanceId, default: 0],
                                                    activeByAccount[entry.providerInstanceId, default: 0])
        defer {
            realActive -= 1
            activeByAccount[entry.providerInstanceId, default: 0] -= 1
        }
        if holdRequests {
            // Intentionally ignores cancellation, like a stuck stream opener.
            await withCheckedContinuation { held[entry.id] = $0 }
        } else {
            try? await Task.sleep(nanoseconds: delays[entry.id] ?? 3_000_000)
        }
        if let error = failures[entry.id] {
            return LatencyProbe(seconds: nil, error: error, retryAllowed: !noRetry.contains(entry.id))
        }
        return LatencyProbe(seconds: 0.3, error: nil)
    }
''' + cache + probe + scheduler + notifications + throttle + '\n}\n'
production_harness = program
# Evaluate the exact production button predicate in Swift alongside the real
# scheduler, so this regression fails if partial coverage disables the UI again.
button_disabled = instance_button.split('let isDisabled = ', 1)[1].split('\n', 1)[0]
button_spinner = instance_button.split('if let joined {', 1)[1].split('if ', 1)[1].split(' {', 1)[0]
program += '''
@MainActor func apiButtonDisabled(_ optimizer: ChatOptimizer, _ instanceId: String) -> Bool {
    let status = optimizer.speedTestStatus
    let joined = status.running ? status.instances[instanceId] : nil
    return ''' + button_disabled + '''
}
@MainActor func apiButtonShowsSpinner(_ joined: InstanceSpeedTestProgress) -> Bool {
    return ''' + button_spinner + '''
}
'''
program += r'''
// All waits observe fake-provider starts/holds, not a guessed scheduling delay.
// The scheduler, progress type and deadline implementation above are unmodified
// production Swift; only the provider response is controlled by this harness.
@MainActor func waitFor(_ description: String, timeout: TimeInterval = 2,
                        _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        precondition(Date() < deadline, "Timed out waiting for \(description)")
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
@MainActor func waitForHeld(_ optimizer: ChatOptimizer, _ id: String,
                           attempt: Int = 1, timeout: TimeInterval = 2) async throws {
    try await waitFor("\(id) attempt \(attempt) to actually start and hold", timeout: timeout) {
        optimizer.starts[id] == attempt && optimizer.held[id] != nil
    }
}
func assertProgressBounds(_ statuses: [String: InstanceSpeedTestProgress]) {
    for value in statuses.values {
        assert(value.total >= 0 && value.done >= 0 && value.done <= value.total)
        assert(value.reached >= 0 && value.reached <= value.total)
        assert(value.skipped >= 0 && value.skipped <= value.done)
        assert(value.displayedPosition == min(value.total, max(value.done, value.reached)))
        assert(value.displayedPosition >= value.done && value.displayedPosition <= value.total)
    }
}
@MainActor func assertInstanceProgress(_ optimizer: ChatOptimizer, _ instanceId: String,
                                       done: Int, reached: Int, total: Int, skipped: Int = 0) {
    guard let value = optimizer.speedTestStatus.instances[instanceId] else {
        preconditionFailure("Missing progress for \(instanceId)")
    }
    assert(value.done == done && value.reached == reached && value.total == total
        && value.skipped == skipped, "Unexpected progress for \(instanceId): \(value)")
    assertProgressBounds([instanceId: value])
}
func entries(_ count: Int, accounts: Int = 4) -> [ModelEntry] {
    (0..<count).map { ModelEntry(id: "m\($0)", providerInstanceId: "a\($0 % accounts)") }
}
@main struct Tests {
    @MainActor static func main() async throws {
        // 100 models across eight accounts: the actual scheduler reaches all six
        // global slots while keeping every provider instance serial, publishes
        // before completion, and never re-probes a duplicate catalog row.
        let parallel = ChatOptimizer()
        parallel.catalog = entries(100, accounts: 8) + entries(1)
        parallel.automatic = parallel.catalog
        var sawLive = false
        var progress: [(Int, Int)] = []
        let firstLeaf = parallel.latencyState.entry(id: "m0")
        let unrelatedLeaf = parallel.latencyState.entry(id: "not-tested")
        var unrelatedPublishes = 0
        let unrelatedSubscription = unrelatedLeaf.$result.dropFirst().sink { _ in unrelatedPublishes += 1 }
        let subscription = firstLeaf.$result.sink { result in
            if result.seconds != nil && parallel.latencyState.cache.entries.count < 100 && parallel.speedTestStatus.running {
                sawLive = true
            }
        }
        await parallel.speedTestAll(sessionId: nil, includeAllAccounts: true) { done, total in
            progress.append((done, total))
        }
        assert(parallel.maxActive == 6 && parallel.maxAccount == 1)
        assert(parallel.starts.count == 100 && parallel.starts.values.allSatisfy { $0 == 1 })
        assert(parallel.latencyState.cache.entries.count == 100 && sawLive)
        assert(progress.last!.0 == 100 && progress.last!.1 == 100)
        let durable = try JSONDecoder().decode(ModelLatencyCache.self,
            from: parallel.userDefaults.data(forKey: ChatOptimizerSettings.latencyCacheKey)!)
        assert(durable.entries == parallel.latencyState.cache.entries)
        assert(parallel.latencyState.entry(id: "m0") === firstLeaf && unrelatedPublishes == 0)
        withExtendedLifetime((subscription, unrelatedSubscription)) {}
        print("PASS: 100 actual Swift probes, stable per-entry publishers, no unrelated invalidation, durable final cache")

        // Manual "all" always remeasures cached successes. A user-selected
        // value above the policy cap is clamped to six global slots, while
        // eight accounts still remain serial independently.
        let repeated = ChatOptimizer()
        repeated.catalog = entries(16, accounts: 8)
        for entry in repeated.catalog { repeated.delays[entry.id] = 20_000_000 }
        await repeated.speedTestAll(sessionId: nil, concurrency: 99, includeAllAccounts: true)
        assert(repeated.maxActive == 6 && repeated.maxAccount == 1)
        assert(repeated.starts.values.allSatisfy { $0 == 1 })
        let firstManualCache = repeated.latencyState.cache.entries
        await repeated.speedTestAll(sessionId: nil, concurrency: 99, includeAllAccounts: true)
        assert(repeated.starts.count == 16 && repeated.starts.values.allSatisfy { $0 == 2 })
        assert(repeated.latencyState.cache.entries == firstManualCache)
        print("PASS: repeated manual all remeasures cached successes; concurrency 99 clamps to six")

        // A single API must not fall back to availableEntries or all accounts.
        let scoped = ChatOptimizer()
        scoped.catalog = entries(12, accounts: 3)
        scoped.automatic = scoped.catalog
        await scoped.speedTestInstance(instanceId: "a1", sessionId: nil)
        assert(Set(scoped.starts.keys) == Set(scoped.catalog.filter { $0.providerInstanceId == "a1" }.map(\.id)))
        assert(scoped.speedTestStatus.instances["a1"]?.done == 4)
        assert(scoped.speedTestStatus.instances["a1"]?.total == 4)
        assert(scoped.speedTestStatus.instances["a0"] == nil)
        await scoped.speedTestInstance(instanceId: "unknown", sessionId: nil)
        assert(scoped.starts.count == 4 && !scoped.speedTestStatus.running)
        print("PASS: API-only request includes exactly its catalog entries; empty API never expands scope")

        // Automatic available-only probes may already include a0, but a tap
        // must still add its hidden/disabled catalog rows, not other APIs'.
        let partial = ChatOptimizer()
        partial.catalog = entries(12, accounts: 3)
        partial.automatic = Array(partial.catalog.prefix(2)) // m0/a0, m1/a1
        partial.holdRequests = true
        let partialRun = Task { @MainActor in await partial.speedTestAll(sessionId: nil) }
        for _ in 0..<1000 {
            if partial.held.count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        assert(partial.held.count == 2 && partial.speedTestStatus.running)
        assert(partial.speedTestStatus.instances["a0"]?.total == 1)
        assert(partial.speedTestStatus.fullInstanceIds.isEmpty)
        assert(!apiButtonDisabled(partial, "a0") && !apiButtonDisabled(partial, "a2"))
        let upgradeAPI = Task { @MainActor in await partial.speedTestInstance(instanceId: "a0", sessionId: nil) }
        for _ in 0..<1000 {
            if partial.speedTestStatus.fullInstanceIds.contains("a0") { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        // The explicit scope locks before waiting for any held probe; a1's
        // automatic partial scope remains enabled and global scope stays false.
        assert(partial.speedTestStatus.fullInstanceIds == Set(["a0"]))
        assert(apiButtonDisabled(partial, "a0") && !apiButtonDisabled(partial, "a1"))
        assert(!partial.speedTestStatus.includesAllAccounts)
        let duplicateAPI = Task { @MainActor in await partial.speedTestInstance(instanceId: "a0", sessionId: nil) }
        for _ in 0..<20 { await Task.yield() }
        partial.holdRequests = false
        partial.releaseHeld()
        await partialRun.value
        await upgradeAPI.value
        await duplicateAPI.value
        let expectedPartial = Set(partial.catalog.filter { $0.providerInstanceId == "a0" }.map(\.id) + ["m1"])
        assert(Set(partial.starts.keys) == expectedPartial && partial.starts.values.allSatisfy { $0 == 1 })
        assertInstanceProgress(partial, "a0", done: 4, reached: 4, total: 4)
        assertInstanceProgress(partial, "a1", done: 1, reached: 1, total: 1)
        assert(partial.speedTestStatus.instances["a2"] == nil)
        assert(!apiButtonDisabled(partial, "a0") && partial.maxActive <= 6 && partial.maxAccount <= 1)
        // A later automatic batch must not inherit the previous explicit lock.
        partial.holdRequests = true
        let nextPartial = Task { @MainActor in await partial.speedTestAll(sessionId: nil) }
        for _ in 0..<1000 {
            if partial.held.count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        assert(partial.held.count == 2 && partial.speedTestStatus.fullInstanceIds.isEmpty)
        assertInstanceProgress(partial, "a0", done: 0, reached: 1, total: 1)
        assertInstanceProgress(partial, "a1", done: 0, reached: 1, total: 1)
        assert(!apiButtonDisabled(partial, "a0"))
        partial.holdRequests = false
        partial.releaseHeld()
        await nextPartial.value
        print("PASS: automatic partial -> full single-API upgrade, pre-await button lock, no unrelated API expansion or duplicates, independent progress, next-batch reset")

        // Two API requests plus duplicate taps merge without probing a third API.
        let apiMerge = ChatOptimizer()
        apiMerge.catalog = entries(18, accounts: 3)
        apiMerge.automatic = apiMerge.catalog
        apiMerge.holdRequests = true
        let apiA = Task { @MainActor in await apiMerge.speedTestInstance(instanceId: "a0", sessionId: nil) }
        for _ in 0..<20 { await Task.yield() }
        let apiB = Task { @MainActor in await apiMerge.speedTestInstance(instanceId: "a1", sessionId: nil) }
        let apiDuplicate = Task { @MainActor in await apiMerge.speedTestInstance(instanceId: "a0", sessionId: nil) }
        for _ in 0..<20 { await Task.yield() }
        assert(apiMerge.speedTestStatus.instances["a1"] != nil)
        apiMerge.holdRequests = false
        apiMerge.releaseHeld()
        await apiA.value
        await apiB.value
        await apiDuplicate.value
        assert(apiMerge.starts.count == 12 && apiMerge.starts.values.allSatisfy { $0 == 1 })
        assert(apiMerge.launchAccounts.allSatisfy { $0 == "a0" || $0 == "a1" })
        assert(apiMerge.speedTestStatus.instances["a0"]?.done == 6)
        assert(apiMerge.speedTestStatus.instances["a1"]?.done == 6)
        assert(apiMerge.maxAccount <= 1 && apiMerge.maxActive <= 6)
        print("PASS: API/API merging, independent progress, duplicate taps, no third-API traffic")

        // A global request can upgrade an API run; an API request can join it.
        let apiGlobal = ChatOptimizer()
        apiGlobal.catalog = entries(12, accounts: 3)
        apiGlobal.holdRequests = true
        let firstAPI = Task { @MainActor in await apiGlobal.speedTestInstance(instanceId: "a0", sessionId: nil) }
        for _ in 0..<20 { await Task.yield() }
        let allAPI = Task { @MainActor in await apiGlobal.speedTestAll(sessionId: nil, includeAllAccounts: true) }
        let joiningAPI = Task { @MainActor in await apiGlobal.speedTestInstance(instanceId: "a2", sessionId: nil) }
        for _ in 0..<20 { await Task.yield() }
        assert(apiGlobal.speedTestStatus.includesAllAccounts)
        assert(apiButtonDisabled(apiGlobal, "a0") && apiButtonDisabled(apiGlobal, "a2"))
        apiGlobal.holdRequests = false
        apiGlobal.releaseHeld()
        await firstAPI.value
        await allAPI.value
        await joiningAPI.value
        assert(apiGlobal.starts.count == 12 && apiGlobal.starts.values.allSatisfy { $0 == 1 })
        assert(apiGlobal.speedTestStatus.instances.values.allSatisfy { $0.done == $0.total && $0.total == 4 })
        assert(apiGlobal.maxActive <= 6 && apiGlobal.maxAccount == 1)
        print("PASS: API/global upgrade and global/API join share one queue without duplicate probes")

        // The extracted production value keeps completion independent from
        // display position, including skipped work and defensive clamping.
        var display = InstanceSpeedTestProgress()
        assert(display.reached == 0 && display.displayedPosition == 0)
        display.total = 7
        display.done = 3
        display.reached = 1
        assert(display.displayedPosition == 3)
        display.reached = 20
        assert(display.displayedPosition == 7)
        display.total = 0
        assert(display.displayedPosition == 0)
        display.total = 7
        display.done = 6
        display.reached = 7
        assert(display.displayedPosition == 7 && apiButtonShowsSpinner(display))
        display.done = 7
        assert(!apiButtonShowsSpinner(display))

        // Artificially hold EVERY response on one seven-row account. Advancing
        // one continuation at a time proves position changes at the real next
        // dispatch, never at enqueue and never by pretending a request finished.
        let positions = ChatOptimizer()
        positions.catalog = entries(7, accounts: 1) + entries(1, accounts: 1)
        positions.holdRequests = true
        var positionFrames: [InstanceSpeedTestProgress] = []
        var completionFrames: [(Int, Int)] = []
        let positionSubscription = positions.speedTestStatus.$instances.sink { statuses in
            assertProgressBounds(statuses)
            if let value = statuses["a0"] { positionFrames.append(value) }
        }
        let positionRun = Task { @MainActor in
            await positions.speedTestAll(sessionId: nil, includeAllAccounts: true) {
                completionFrames.append(($0, $1))
            }
        }
        for position in 1...7 {
            let id = "m\(position - 1)"
            try await waitForHeld(positions, id)
            assertInstanceProgress(positions, "a0", done: position - 1, reached: position, total: 7)
            assert(positions.starts.count == position && positions.starts.values.allSatisfy { $0 == 1 })
            assert(positions.latencyState.cache.entries.count == position - 1)
            assert(completionFrames.last!.0 == position - 1 && completionFrames.last!.1 == 7)
            assert(apiButtonShowsSpinner(positions.speedTestStatus.instances["a0"]!))
            assert(positionFrames.contains { $0.done == position - 1 && $0.reached == position })
            positions.held.removeValue(forKey: id)!.resume()
        }
        await positionRun.value
        assertInstanceProgress(positions, "a0", done: 7, reached: 7, total: 7)
        assert(completionFrames.last!.0 == 7 && completionFrames.last!.1 == 7)
        assert(!apiButtonShowsSpinner(positions.speedTestStatus.instances["a0"]!))
        assert(positions.maxAccount == 1 && positions.starts.count == 7)
        assert(positionFrames.contains { $0.total == 7 && $0.done == 0 && $0.reached == 0 })
        assert(zip(positionFrames, positionFrames.dropFirst()).allSatisfy { $0.0.reached <= $0.1.reached })
        withExtendedLifetime(positionSubscription) {}
        print("PASS: real serial dispatch publishes 1/7 before first completion, 2/7 only at second start, through 7/7 while still spinning, then done=7; duplicate catalog row counted once")

        // Hold account B's first request while A advances through ALL seven.
        // Then reverse the roles: neither account may borrow the other's starts,
        // completed count or total, even when A has already reached its end.
        let independent = ChatOptimizer()
        independent.catalog = entries(14, accounts: 2)
        independent.holdRequests = true
        let independentSubscription = independent.speedTestStatus.$instances.sink {
            assertProgressBounds($0)
        }
        let independentRun = Task { @MainActor in
            await independent.speedTestAll(sessionId: nil, includeAllAccounts: true)
        }
        try await waitForHeld(independent, "m0")
        try await waitForHeld(independent, "m1")
        assertInstanceProgress(independent, "a0", done: 0, reached: 1, total: 7)
        assertInstanceProgress(independent, "a1", done: 0, reached: 1, total: 7)
        for account in 0..<2 {
            for position in 1...7 {
                let id = "m\((position - 1) * 2 + account)"
                try await waitForHeld(independent, id)
                assertInstanceProgress(independent, "a\(account)",
                    done: position - 1, reached: position, total: 7)
                assertInstanceProgress(independent, account == 0 ? "a1" : "a0",
                    done: account == 0 ? 0 : 7, reached: account == 0 ? 1 : 7, total: 7)
                independent.held.removeValue(forKey: id)!.resume()
            }
            try await waitFor("account a\(account) to finish") {
                independent.speedTestStatus.instances["a\(account)"]?.done == 7
            }
        }
        await independentRun.value
        assertInstanceProgress(independent, "a0", done: 7, reached: 7, total: 7)
        assertInstanceProgress(independent, "a1", done: 7, reached: 7, total: 7)
        assert(independent.starts.count == 14 && independent.starts.values.allSatisfy { $0 == 1 })
        assert(independent.maxAccount == 1 && independent.maxActive == 2)
        withExtendedLifetime(independentSubscription) {}
        print("PASS: two real seven-row accounts advance independently with all published positions bounded")

        // A SINGLE account is strictly serial and never consumes more than one
        // request slot.
        let single = ChatOptimizer()
        single.catalog = entries(12, accounts: 1)
        await single.speedTestAll(sessionId: nil, includeAllAccounts: true)
        assert(single.maxActive == 1 && single.maxAccount == 1)
        print("PASS: single-account concurrency cap")

        // Eleven models on each Today account are serial, not globally serial:
        // a second Today account and one ordinary-account slot still proceed.
        let todayBatch = ChatOptimizer()
        todayBatch.store.todayAccounts = ["today-A", "today-B"]
        let todayA = (0..<11).map { ModelEntry(id: "ta\($0)", providerInstanceId: "today-A") }
        let todayB = (0..<11).map { ModelEntry(id: "tb\($0)", providerInstanceId: "today-B") }
        let ordinary = (0..<8).map { ModelEntry(id: "o\($0)", providerInstanceId: "ordinary") }
        todayBatch.catalog = todayA + todayB + ordinary
        await todayBatch.speedTestAll(sessionId: nil, includeAllAccounts: true)
        assert(todayBatch.starts.count == 30 && todayBatch.starts.values.allSatisfy { $0 == 1 })
        assert(todayBatch.maxByAccount["today-A"] == 1 && todayBatch.maxByAccount["today-B"] == 1)
        assert(todayBatch.maxByAccount["ordinary"] == 1 && todayBatch.maxActive == 3)
        assert(todayBatch.speedTestStatus.instances["today-A"]?.done == 11)
        assert(todayBatch.latencyState.cache.entries.count == 30)
        assert(TodayCompletionPolicy.pollingTimeout == 120 && TodayCompletionPolicy.requestTimeout == 30)
        assert(LatencyProbePolicy(isToday: true).timeout == 240)
        assert(LatencyProbePolicy(isToday: false).timeout == 12)
        assert(LatencyProbePolicy(isToday: true).accountLimit == 1)
        assert(LatencyProbePolicy(isToday: false).accountLimit == 1)
        print("PASS: eleven-model Today accounts serial; mixed provider instances each use one global slot")

        // Real production deadline timers, not a Python timing approximation:
        // a 15.9-second completion survives Today defaults but not ordinary TTFT.
        let slowToday = ChatOptimizer()
        slowToday.store.todayAccounts = ["today"]
        slowToday.catalog = [ModelEntry(id: "today-slow", providerInstanceId: "today"),
                             ModelEntry(id: "ordinary-slow", providerInstanceId: "ordinary")]
        for entry in slowToday.catalog { slowToday.delays[entry.id] = 15_900_000_000 }
        await slowToday.speedTestAll(sessionId: nil, includeAllAccounts: true)
        assert(slowToday.latencyState.cache.entries["today-slow"] != nil)
        assert(slowToday.latencyState.entry(id: "ordinary-slow").result.isTimeout)
        assert(slowToday.latencyState.cache.unavailable.isEmpty)
        print("PASS: simulated 15.9s completed reply survives Today-only default budget; others still expire at 12s")

        // Start automatic, then upgrade manually from two independent callers.
        // Both join the SAME run; hidden/disabled extra catalog entries are added.
        let joined = ChatOptimizer()
        joined.catalog = entries(8, accounts: 4)
        joined.automatic = Array(joined.catalog.prefix(4))
        for entry in joined.catalog { joined.delays[entry.id] = 30_000_000 }
        var totals: [(Int, Int)] = []
        let automatic = Task { @MainActor in
            await joined.speedTestAll(sessionId: nil) { totals.append(($0, $1)) }
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        let manual = Task { @MainActor in
            await joined.speedTestAll(sessionId: nil, includeAllAccounts: true)
        }
        let duplicate = Task { @MainActor in
            await joined.speedTestAll(sessionId: nil, includeAllAccounts: true)
        }
        await manual.value
        await automatic.value
        await duplicate.value
        assert(joined.starts.count == 8 && joined.starts.values.allSatisfy { $0 == 1 })
        assert(totals.last!.0 == 8 && totals.last!.1 == 8)
        assert(!joined.speedTestStatus.running && joined.maxActive <= 6)
        // A newly attached/reopened leaf gets the whole CURRENT snapshot at once.
        var reopened: Double?
        let reopenedLeaf = joined.latencyState.entry(id: "m0").$result.sink { reopened = $0.seconds }
        assert(reopened == 0.3)
        withExtendedLifetime(reopenedLeaf) {}
        print("PASS: automatic/manual upgrade, cross-picker reentry, reopened leaf replay")

        // Success -> failure -> recovery: no stale success may hide a failure;
        // errors stay UI-only and must never populate the hard-unavailable list.
        let soft = ChatOptimizer()
        soft.catalog = entries(1, accounts: 1)
        soft.latencyState.cache.entries["m0"] = 9
        soft.failures["m0"] = "network unavailable"
        await soft.speedTestAll(sessionId: nil, includeAllAccounts: true)
        assert(soft.latencyState.cache.entries["m0"] == nil)
        assert(soft.latencyState.cache.errors["m0"] == "network unavailable")
        assert(soft.latencyState.cache.unavailable.isEmpty)
        soft.failures.removeAll()
        await soft.speedTestAll(sessionId: nil, includeAllAccounts: true)
        assert(soft.latencyState.cache.entries["m0"] != nil && soft.latencyState.cache.errors["m0"] == nil)
        print("PASS: stale-success invalidation, soft failure and recovery")

        // Quick Test measures completed response latency and immediately
        // updates the stable leaf and durable cache for any provider.
        let liveToday = ChatOptimizer()
        liveToday.store.todayAccounts = ["today-live"]
        let liveTodayEntry = ModelEntry(id: "today-live-model", providerInstanceId: "today-live")
        liveToday.catalog = [liveTodayEntry]
        liveToday.latencyState.cache.entries[liveTodayEntry.id] = 8.1
        let liveTodayLeaf = liveToday.latencyState.entry(id: liveTodayEntry.id)
        liveToday.recordSuccessfulTextQuickTest(entry: liveTodayEntry, elapsed: 4.0)
        assert(liveTodayLeaf.result.seconds == 4.0)
        assert(liveToday.latencyState.cache.entries[liveTodayEntry.id] == 4.0)
        let liveTodayDurable = try JSONDecoder().decode(ModelLatencyCache.self,
            from: liveToday.userDefaults.data(forKey: ChatOptimizerSettings.latencyCacheKey)!)
        assert(liveTodayDurable.entries[liveTodayEntry.id] == 4.0)
        let liveOrdinary = ChatOptimizer()
        let liveOrdinaryEntry = ModelEntry(id: "glm-flash", providerInstanceId: "glm-instance")
        liveOrdinary.catalog = [liveOrdinaryEntry]
        liveOrdinary.latencyState.cache.entries[liveOrdinaryEntry.id] = 3.0
        let liveOrdinaryLeaf = liveOrdinary.latencyState.entry(id: liveOrdinaryEntry.id)
        liveOrdinary.recordSuccessfulTextQuickTest(entry: liveOrdinaryEntry, elapsed: 4.0)
        assert(liveOrdinaryLeaf.result.seconds == 4.0)
        assert(liveOrdinary.latencyState.cache.entries[liveOrdinaryEntry.id] == 4.0)
        let liveOrdinaryDurable = try JSONDecoder().decode(ModelLatencyCache.self,
            from: liveOrdinary.userDefaults.data(forKey: ChatOptimizerSettings.latencyCacheKey)!)
        assert(liveOrdinaryDurable.entries[liveOrdinaryEntry.id] == 4.0)
        print("PASS: Quick Test publishes completed latency to the live row and durable cache for all providers")

        // A successful TEXT smoke test clears only this entry's old failure.
        // Without a measured duration, it preserves any existing probe value.
        let verified = ChatOptimizer()
        let verifiedEntry = ModelEntry(id: "verified", providerInstanceId: "today")
        verified.catalog = [verifiedEntry]
        verified.latencyState.cache.errors = ["verified": "first-token timeout", "other": "failure"]
        verified.latencyState.cache.unavailable = ["verified"]
        let verifiedLeaf = verified.latencyState.entry(id: "verified")
        assert(verifiedLeaf.result.isTimeout)
        verified.recordSuccessfulTextQuickTest(entry: verifiedEntry)
        assert(verifiedLeaf.result.error == nil && verifiedLeaf.result.seconds == nil)
        assert(verified.latencyState.cache.entries.isEmpty && verified.latencyState.cache.unavailable.isEmpty)
        assert(verified.latencyState.cache.errors["other"] == "failure")
        let verifiedDurable = try JSONDecoder().decode(ModelLatencyCache.self,
            from: verified.userDefaults.data(forKey: ChatOptimizerSettings.latencyCacheKey)!)
        assert(verifiedDurable.errors["verified"] == nil)
        verified.latencyState.cache.entries["verified"] = 1.7
        verified.recordSuccessfulTextQuickTest(entry: verifiedEntry)
        assert(verifiedLeaf.result.seconds == 1.7)
        verified.holdRequests = true
        verified.failures["verified"] = "old failed probe"
        let oldRun = Task { @MainActor in await verified.speedTestAll(sessionId: nil, includeAllAccounts: true) }
        for _ in 0..<1000 { if verified.held.count == 1 { break }; await Task.yield() }
        assert(verified.held.count == 1)
        verified.recordSuccessfulTextQuickTest(entry: verifiedEntry)
        assert(verifiedLeaf.result.phase == .running)
        verified.releaseHeld()
        await oldRun.value
        assert(verifiedLeaf.result.error == nil && verifiedLeaf.result.seconds == 1.7)
        verified.holdRequests = false
        await verified.speedTestAll(sessionId: nil, includeAllAccounts: true)
        assert(verifiedLeaf.result.error == "old failed probe" && verifiedLeaf.result.seconds == nil)
        print("PASS: text Quick Test clears exact failure, persists, preserves measured TTFT and supersedes older probe failures only")

        // A 429 while polling an already-submitted Today generation must exhaust
        // that account, NOT issue a second paid POST. Other accounts finish.
        let delivered = ChatOptimizer()
        delivered.store.todayAccounts = ["today"]
        delivered.catalog = (0..<11).map { ModelEntry(id: "paid\($0)", providerInstanceId: "today") }
            + [ModelEntry(id: "healthy", providerInstanceId: "other")]
        delivered.failures["paid0"] = "HTTP 429 rate limited"
        delivered.noRetry = ["paid0"]
        await delivered.speedTestAll(sessionId: nil, includeAllAccounts: true)
        assert(delivered.starts["paid0"] == 1 && delivered.starts.count == 2)
        assert(delivered.speedTestStatus.instances["today"]?.skipped == 11)
        assert(delivered.latencyState.cache.errors["paid0"] == "Rate limited")
        assert(delivered.latencyState.cache.errors["healthy"] == nil)
        assert(delivered.latencyState.cache.unavailable.isEmpty)
        print("PASS: delivered Today polling throttle never resends generation, skips account safely, other account completes")

        // Permanently rate-limited account is retried once after cooldown, then
        // skipped. The healthy account must finish BEFORE that cooldown ends.
        let throttled = ChatOptimizer()
        let bad = (0..<7).map { ModelEntry(id: "bad\($0)", providerInstanceId: "rate") }
        let good = (0..<4).map { ModelEntry(id: "good\($0)", providerInstanceId: "good") }
        let safeToday = [ModelEntry(id: "safeToday0", providerInstanceId: "safe-today")]
        throttled.store.todayAccounts = ["safe-today"]
        throttled.catalog = bad + good + safeToday
        for entry in bad + safeToday { throttled.failures[entry.id] = "HTTP 429 rate limited" }
        throttled.latencyState.cache.entries["bad0"] = 1.2
        throttled.holdRequests = true
        var rateFrames: [InstanceSpeedTestProgress] = []
        let rateSubscription = throttled.speedTestStatus.$instances.sink { statuses in
            assertProgressBounds(statuses)
            if let value = statuses["rate"] { rateFrames.append(value) }
        }
        var finalProgress = (0, 0)
        let throttleRun = Task { @MainActor in
            await throttled.speedTestAll(sessionId: nil, includeAllAccounts: true) { finalProgress = ($0, $1) }
        }
        try await waitForHeld(throttled, "bad0")
        assertInstanceProgress(throttled, "rate", done: 0, reached: 1, total: 7)
        throttled.holdRequests = false
        throttled.releaseHeld()
        try await waitFor("healthy account to finish while both throttled accounts cool down") {
            good.allSatisfy { throttled.latencyState.cache.entries[$0.id] != nil }
                && throttled.latencyState.cache.errors["bad0"] == "Rate limited"
                && throttled.latencyState.cache.errors["safeToday0"] == "Rate limited"
        }
        assert(throttled.speedTestStatus.running && throttled.starts["bad0"] == 1)
        assertInstanceProgress(throttled, "rate", done: 0, reached: 1, total: 7)
        assertInstanceProgress(throttled, "good", done: 4, reached: 4, total: 4)
        // Keep the real eight-second production cooldown, then hold the SECOND
        // actual attempt so a duplicated reached count cannot hide in a fast 429.
        throttled.holdRequests = true
        try await waitForHeld(throttled, "bad0", attempt: 2, timeout: 12)
        assertInstanceProgress(throttled, "rate", done: 0, reached: 1, total: 7)
        assert(rateFrames.allSatisfy { $0.reached <= 1 && $0.done == 0 })
        throttled.holdRequests = false
        throttled.releaseHeld()
        await throttleRun.value
        assert(throttled.maxAccount <= 1 && throttled.starts.values.allSatisfy { $0 <= 2 })
        assert(throttled.starts["bad0"] == 2)
        assert((1..<7).allSatisfy { throttled.starts["bad\($0)"] == nil })
        assert(throttled.latencyState.cache.errors["bad0"] == "Rate limited")
        assert((1..<7).allSatisfy { throttled.latencyState.cache.errors["bad\($0)"] == "Rate limited" })
        assert(throttled.latencyState.cache.errors["safeToday0"] == "Rate limited")
        assert(throttled.latencyState.cache.unavailable.isEmpty)
        assert(throttled.latencyState.cache.entries["bad0"] == 1.2)
        assert(finalProgress.0 == 12 && finalProgress.1 == 12 && throttled.speedTestStatus.skipped == 8)
        assertInstanceProgress(throttled, "rate", done: 7, reached: 7, total: 7, skipped: 7)
        assertInstanceProgress(throttled, "good", done: 4, reached: 4, total: 4)
        assertInstanceProgress(throttled, "safe-today", done: 1, reached: 1, total: 1, skipped: 1)
        for position in 2...7 {
            assert(rateFrames.contains {
                $0.reached == position && $0.done == position && $0.skipped == position
            })
        }
        assert(zip(rateFrames, rateFrames.dropFirst()).allSatisfy { $0.0.reached <= $0.1.reached })
        assert(throttled.maxByAccount["safe-today"] == 1 && throttled.starts["safeToday0"] == 2)
        withExtendedLifetime(rateSubscription) {}
        print("PASS: actual repeated 429 keeps reached=1/done=0 at retry; skipped pump rows publish positions 2...7 and finish done=7/skipped=7, healthy account proceeds independently")

        // A stream opener that ignores cancellation MUST NOT hold the scheduler
        // hostage or be replaced by unbounded new requests. Late success cannot
        // overwrite a timeout or any next run's in-memory cache.
        let stuck = ChatOptimizer()
        stuck.catalog = entries(6, accounts: 1)
        stuck.holdRequests = true
        var stuckProgress = (0, 0)
        let begin = Date()
        await stuck.speedTestAll(sessionId: nil, perEntryTimeout: 0.02, includeAllAccounts: true) {
            stuckProgress = ($0, $1)
        }
        assert(Date().timeIntervalSince(begin) < 1)
        assert(stuck.starts.count == 1 && stuck.activeCount == 1 && stuck.maxAccount == 1)
        assert(stuckProgress.0 == 6 && stuckProgress.1 == 6 && stuck.speedTestStatus.skipped == 5)
        assert(stuck.speedTestStatus.instances["a0"]?.displayedPosition == 6)
        assertProgressBounds(stuck.speedTestStatus.instances)
        assert(stuck.latencyState.cache.errors.count == 1 && stuck.latencyState.cache.entries.isEmpty)
        await stuck.speedTestAll(sessionId: nil, perEntryTimeout: 0.02, includeAllAccounts: true)
        assert(stuck.starts.count == 1 && stuck.speedTestStatus.skipped == 6)
        assert(stuck.speedTestStatus.instances["a0"]?.displayedPosition == 6)
        assertProgressBounds(stuck.speedTestStatus.instances)
        stuck.releaseHeld()
        for _ in 0..<20 { await Task.yield() }
        assert(stuck.activeCount == 0 && stuck.latencyState.cache.entries.isEmpty)
        print("PASS: hard deadline without task join, retained account permits, no overlap/late-cache overwrite")

        let todayStuck = ChatOptimizer()
        todayStuck.store.todayAccounts = ["today"]
        todayStuck.catalog = (0..<11).map { ModelEntry(id: "st\($0)", providerInstanceId: "today") }
        todayStuck.holdRequests = true
        await todayStuck.speedTestAll(sessionId: nil, perEntryTimeout: 0.02, includeAllAccounts: true)
        assert(todayStuck.starts.count == 1 && todayStuck.activeCount == 1)
        assert(todayStuck.speedTestStatus.skipped == 10)
        assert(todayStuck.latencyState.entry(id: "st0").result.isTimeout)
        await todayStuck.speedTestAll(sessionId: nil, perEntryTimeout: 0.02, includeAllAccounts: true)
        assert(todayStuck.starts.count == 1 && todayStuck.speedTestStatus.skipped == 11)
        todayStuck.releaseHeld()
        for _ in 0..<100 { await Task.yield() }
        assert(todayStuck.activeCount == 0 && todayStuck.latencyState.cache.entries.isEmpty)
        print("PASS: Today explicit deadline override, retained single account permit and late-result rejection")

        // The same guarantee holds globally, across many different accounts.
        let globallyStuck = ChatOptimizer()
        globallyStuck.catalog = entries(10, accounts: 10)
        globallyStuck.holdRequests = true
        await globallyStuck.speedTestAll(sessionId: nil, perEntryTimeout: 0.02, includeAllAccounts: true)
        assert(globallyStuck.maxActive == 6 && globallyStuck.activeCount == 6)
        assert(globallyStuck.starts.count == 6 && globallyStuck.speedTestStatus.skipped == 4)
        await globallyStuck.speedTestAll(sessionId: nil, perEntryTimeout: 0.02, includeAllAccounts: true)
        assert(globallyStuck.starts.count == 6)
        globallyStuck.releaseHeld()
        for _ in 0..<20 { await Task.yield() }
        assert(globallyStuck.activeCount == 0)
        print("PASS: retained global permits across noncooperative timeout and subsequent runs")

        // Cancellation is not a model defect and must not dispatch more models.
        let cancelled = ChatOptimizer()
        cancelled.catalog = entries(30, accounts: 8)
        cancelled.holdRequests = true
        let cancellationSubscription = cancelled.speedTestStatus.$instances.sink {
            assertProgressBounds($0)
        }
        let cancellable = Task { @MainActor in
            await cancelled.speedTestAll(sessionId: nil, includeAllAccounts: true)
        }
        for index in 0..<6 { try await waitForHeld(cancelled, "m\(index)") }
        let cancellationSnapshot = cancelled.speedTestStatus.instances
        assert(cancelled.starts.count == 6 && cancelled.activeCount == 6)
        for account in 0..<8 {
            assertInstanceProgress(cancelled, "a\(account)", done: 0,
                reached: account < 6 ? 1 : 0, total: account < 6 ? 4 : 3)
        }
        cancellable.cancel()
        await cancellable.value
        assert(cancelled.starts.count == 6 && !cancelled.speedTestStatus.running)
        assert(cancelled.speedTestStatus.instances == cancellationSnapshot)
        assert(cancelled.latencyState.cache.errors.isEmpty && cancelled.speedTestStatus.skipped == 0)
        // These producers ignore cancellation: releasing their continuations
        // must not create new dispatches, completion credit or late progress.
        cancelled.releaseHeld()
        try await waitFor("cancelled producers to release their retained permits") { cancelled.activeCount == 0 }
        assert(cancelled.speedTestStatus.instances == cancellationSnapshot)
        let preCancelled = Task { @MainActor in
            await cancelled.speedTestAll(sessionId: nil, includeAllAccounts: true)
        }
        preCancelled.cancel()
        await preCancelled.value
        assert(cancelled.starts.count == 6 && cancelled.speedTestStatus.instances == cancellationSnapshot)
        withExtendedLifetime(cancellationSubscription) {}
        print("PASS: in-flight/pre-start cancellation freezes bounded per-account reached/done, no red failures, no extra dispatch or late progress")
        print("PASS: all production speed-test runtime regressions")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='speedtest-regression-') as tmp:
    swift = Path(tmp) / 'SpeedTestRegression.swift'
    binary = Path(tmp) / 'speedtest-regression'
    swift.write_text(program)
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(swift), '-o', str(binary)],
                   check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=90)
    from speedtest_probe_clock import run_probe_clock_test
    run_probe_clock_test(source, production_harness, Path(tmp))
    from speedtest_swiftui_host import run_swiftui_test
    run_swiftui_test(production_harness, picker, Path(tmp))
