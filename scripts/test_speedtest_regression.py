#!/usr/bin/env python3
"""Regression-test the production speed-test scheduler/deadline (no network).

Linux: --static-only. macOS CI: compiles extracted, unmodified Swift methods
against a fake provider/catalog. This is not a Python reimplementation of the
scheduler. UIKit geometry still requires device/UI validation.
"""
from pathlib import Path
import argparse
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'src/ios/Agent/Chat/ChatOptimizer.swift').read_text()
picker = (ROOT / 'src/ios/Views/Providers/UnifiedModelPicker.swift').read_text()


def section(start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


checks = {
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
    'default bounded parallelism and per-account cap':
        'concurrency: Int = 4' in source and 'let accountLimit = min(2, globalLimit)' in source,
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
        'for entry in queue { complete(entry.providerInstanceId, skipped: true) }' in source,
    'header button invokes scoped entry point, not global':
        'InstanceSpeedTestButton(instanceId: item.instance.id' in picker
        and 'ChatOptimizer.shared.speedTestInstance(' in picker,
    'partial automatic API scope stays upgradeable; explicit full scope locks before suspension':
        '.disabled(joined != nil && (status.includesAllAccounts || status.fullInstanceIds.contains(instanceId)))' in picker
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
probe = section('    func measureLatency(', '    private func performLatencyProbe(')
scheduler = section('    func speedTestInstance(', '    /// Compatibility signal')
notifications = section('    static let latencyUpdatedNotification', '    /// Whether a probe failure means')
throttle = section('    private static func isThrottle(', '    /// The fastest available entry per the latency cache')

program = 'import Foundation\nimport Combine\n' + types + r'''
struct ModelEntry: Sendable { let id: String; let providerInstanceId: String }
enum ChatOptimizerSettings { static let latencyCacheKey = "speedtest-regression" }
struct TestLog { func info(_ text: String) {} }
@MainActor final class ChatOptimizer {
''' + fields + r'''
    let userDefaults = UserDefaults(suiteName: UUID().uuidString)!
    let logger = TestLog()
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
        if let error = failures[entry.id] { return LatencyProbe(seconds: nil, error: error) }
        return LatencyProbe(seconds: 0.3, error: nil)
    }
''' + cache + probe + scheduler + notifications + throttle + '\n}\n'
production_harness = program
# Evaluate the exact production button predicate in Swift alongside the real
# scheduler, so this regression fails if partial coverage disables the UI again.
instance_button = picker[picker.index('    private struct InstanceSpeedTestButton: View'):]
button_disabled = instance_button.split('.disabled(', 1)[1].split('\n', 1)[0][:-1]
program += '''
@MainActor func apiButtonDisabled(_ optimizer: ChatOptimizer, _ instanceId: String) -> Bool {
    let status = optimizer.speedTestStatus
    let joined = status.running ? status.instances[instanceId] : nil
    return ''' + button_disabled + '''
}
'''
program += r'''
func entries(_ count: Int, accounts: Int = 4) -> [ModelEntry] {
    (0..<count).map { ModelEntry(id: "m\($0)", providerInstanceId: "a\($0 % accounts)") }
}
@main struct Tests {
    @MainActor static func main() async throws {
        // 100 models: actual scheduler reaches four global/two-account slots,
        // publishes before completion, never re-probes a duplicate catalog row.
        let parallel = ChatOptimizer()
        parallel.catalog = entries(100) + entries(1)
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
        assert(parallel.maxActive == 4 && parallel.maxAccount <= 2)
        assert(parallel.starts.count == 100 && parallel.starts.values.allSatisfy { $0 == 1 })
        assert(parallel.latencyState.cache.entries.count == 100 && sawLive)
        assert(progress.last!.0 == 100 && progress.last!.1 == 100)
        let durable = try JSONDecoder().decode(ModelLatencyCache.self,
            from: parallel.userDefaults.data(forKey: ChatOptimizerSettings.latencyCacheKey)!)
        assert(durable.entries == parallel.latencyState.cache.entries)
        assert(parallel.latencyState.entry(id: "m0") === firstLeaf && unrelatedPublishes == 0)
        withExtendedLifetime((subscription, unrelatedSubscription)) {}
        print("PASS: 100 actual Swift probes, stable per-entry publishers, no unrelated invalidation, durable final cache")

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
        assert(partial.speedTestStatus.instances["a0"] == InstanceSpeedTestProgress(done: 4, total: 4, skipped: 0))
        assert(partial.speedTestStatus.instances["a1"] == InstanceSpeedTestProgress(done: 1, total: 1, skipped: 0))
        assert(partial.speedTestStatus.instances["a2"] == nil)
        assert(!apiButtonDisabled(partial, "a0") && partial.maxActive <= 4 && partial.maxAccount <= 2)
        // A later automatic batch must not inherit the previous explicit lock.
        partial.holdRequests = true
        let nextPartial = Task { @MainActor in await partial.speedTestAll(sessionId: nil) }
        for _ in 0..<1000 {
            if partial.held.count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        assert(partial.held.count == 2 && partial.speedTestStatus.fullInstanceIds.isEmpty)
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
        assert(apiMerge.maxAccount <= 2 && apiMerge.maxActive <= 4)
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
        print("PASS: API/global upgrade and global/API join share one queue without duplicate probes")

        // A SINGLE account never consumes more than two request slots.
        let single = ChatOptimizer()
        single.catalog = entries(12, accounts: 1)
        await single.speedTestAll(sessionId: nil, includeAllAccounts: true)
        assert(single.maxActive == 2 && single.maxAccount == 2)
        print("PASS: single-account concurrency cap")

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
        assert(!joined.speedTestStatus.running && joined.maxActive <= 4)
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

        // Permanently rate-limited account is retried once after cooldown, then
        // skipped. The healthy account must finish BEFORE that cooldown ends.
        let throttled = ChatOptimizer()
        let bad = (0..<6).map { ModelEntry(id: "bad\($0)", providerInstanceId: "rate") }
        let good = (0..<4).map { ModelEntry(id: "good\($0)", providerInstanceId: "good") }
        throttled.catalog = bad + good
        for entry in bad { throttled.failures[entry.id] = "HTTP 429 rate limited" }
        throttled.latencyState.cache.entries["bad0"] = 1.2
        var finalProgress = (0, 0)
        let throttleRun = Task { @MainActor in
            await throttled.speedTestAll(sessionId: nil, includeAllAccounts: true) { finalProgress = ($0, $1) }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        assert(good.allSatisfy { throttled.latencyState.cache.entries[$0.id] != nil })
        assert(throttled.speedTestStatus.running)
        await throttleRun.value
        assert(throttled.maxAccount <= 2 && throttled.starts.values.allSatisfy { $0 <= 2 })
        assert(throttled.latencyState.cache.errors.isEmpty && throttled.latencyState.cache.unavailable.isEmpty)
        assert(throttled.latencyState.cache.entries["bad0"] == 1.2)
        assert(finalProgress.0 == 10 && finalProgress.1 == 10 && throttled.speedTestStatus.skipped > 0)
        print("PASS: account-scoped 429 cooldown/retry/skip, healthy account proceeds, progress terminates")

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
        assert(stuck.starts.count == 2 && stuck.activeCount == 2 && stuck.maxAccount == 2)
        assert(stuckProgress.0 == 6 && stuckProgress.1 == 6 && stuck.speedTestStatus.skipped == 4)
        assert(stuck.latencyState.cache.errors.count == 2 && stuck.latencyState.cache.entries.isEmpty)
        await stuck.speedTestAll(sessionId: nil, perEntryTimeout: 0.02, includeAllAccounts: true)
        assert(stuck.starts.count == 2 && stuck.speedTestStatus.skipped == 6)
        stuck.releaseHeld()
        for _ in 0..<20 { await Task.yield() }
        assert(stuck.activeCount == 0 && stuck.latencyState.cache.entries.isEmpty)
        print("PASS: hard deadline without task join, retained account permits, no overlap/late-cache overwrite")

        // The same guarantee holds globally, across many different accounts.
        let globallyStuck = ChatOptimizer()
        globallyStuck.catalog = entries(10, accounts: 10)
        globallyStuck.holdRequests = true
        await globallyStuck.speedTestAll(sessionId: nil, perEntryTimeout: 0.02, includeAllAccounts: true)
        assert(globallyStuck.maxActive == 4 && globallyStuck.activeCount == 4)
        assert(globallyStuck.starts.count == 4 && globallyStuck.speedTestStatus.skipped == 6)
        await globallyStuck.speedTestAll(sessionId: nil, perEntryTimeout: 0.02, includeAllAccounts: true)
        assert(globallyStuck.starts.count == 4)
        globallyStuck.releaseHeld()
        for _ in 0..<20 { await Task.yield() }
        assert(globallyStuck.activeCount == 0)
        print("PASS: retained global permits across noncooperative timeout and subsequent runs")

        // Cancellation is not a model defect and must not dispatch more models.
        let cancelled = ChatOptimizer()
        cancelled.catalog = entries(30)
        for entry in cancelled.catalog { cancelled.delays[entry.id] = 500_000_000 }
        let cancellable = Task { @MainActor in
            await cancelled.speedTestAll(sessionId: nil, includeAllAccounts: true)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        cancellable.cancel()
        await cancellable.value
        for _ in 0..<20 { await Task.yield() }
        assert(cancelled.starts.count <= 4 && !cancelled.speedTestStatus.running)
        assert(cancelled.latencyState.cache.errors.isEmpty && cancelled.activeCount == 0)
        let preCancelled = Task { @MainActor in
            await cancelled.speedTestAll(sessionId: nil, includeAllAccounts: true)
        }
        preCancelled.cancel()
        await preCancelled.value
        assert(cancelled.starts.count <= 4)
        print("PASS: in-flight/pre-start cancellation, no red failures, no extra dispatch")
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
    subprocess.run([str(binary)], check=True, timeout=45)
    from speedtest_probe_clock import run_probe_clock_test
    run_probe_clock_test(source, production_harness, Path(tmp))
    from speedtest_swiftui_host import run_swiftui_test
    run_swiftui_test(production_harness, picker, Path(tmp))
