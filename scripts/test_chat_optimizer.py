#!/usr/bin/env python3
"""Static wiring checks for the chat auto-helpers ported from 1.16.

Covers the parts that live across files and would silently regress:
  * ChatOptimizer exists, is in the Xcode target, and probes through both the
    plain streamMessage envelope AND the agent-shaped one;
  * the speed test is a SOFT signal (a failure records an error but must never
    add the entry to `unavailable`, which would grey out working models);
  * performSend applies the auto rules before the turn is built, and
    cancellation/errors are handled after it;
  * the picker shows latency badges, has the manual speed-test button, and
    reads the cache off the main actor.
"""
from pathlib import Path
import argparse
import re
import sys
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ROOT = Path(__file__).resolve().parents[1]
OPT = ROOT / "src/ios/Agent/Chat/ChatOptimizer.swift"
PBX = ROOT / "src/ios/Minis.xcodeproj/project.pbxproj"
SEND = ROOT / "src/ios/Views/Chat/AIChatView/AIChatView+Send.swift"
COMPOSER = ROOT / "src/ios/Views/Chat/AIChatView/AIChatView+ComposerControls.swift"
PICKER = ROOT / "src/ios/Views/Providers/UnifiedModelPicker.swift"
SETTINGS = ROOT / "src/ios/Views/Settings/SettingsSheet.swift"

CHECKS = [
    (OPT, "single-shot probe uses the lightweight envelope", "provider.streamMessage("),
    (OPT, "failed probe retries through the agent path", "retrying via agent path"),
    (OPT, "agent-path probe builds the agent provider",
     "AIChatViewModel.makeAgentProvider("),
    (OPT, "agent-path probe drives the agent stream", "streamAgentMessageClamped("),
    (OPT, "probe returns on the FIRST token", "case .text(let t) = chunk, !t.isEmpty"),
    (OPT, "failed probe records an error", "latencyState.cache.errors[id] = probe.error"),
    (OPT, "speed-test failure never hard-excludes a model",
     "latencyState.cache.unavailable.removeAll { $0 == id }"),
    (OPT, "fastest entry is picked from measured latencies", "func fastestEntry()"),
    (OPT, "auto-pick honours a user-pinned model", "isManuallyPinned(for: sessionId)"),
    (OPT, "auto-switch defaults ON when unset",
     "UserDefaults.standard.object(forKey: ChatOptimizerSettings.autoSwitchUnavailable) == nil"),
    (OPT, "replacement prefers a model known to work", "let known = pool.filter"),
    (OPT, "rewrite candidates are buffered before replay",
     "Collect each candidate's"),
    (PBX, "ChatOptimizer.swift is compiled into the app", "ChatOptimizer.swift in Sources"),
    (SEND, "auto rules run before the turn is built",
     "await self.ensureSessionThenApplyAutoRules()"),
    (SEND, "the actual send happens after the rules", "self.performSendNow(afterVoice: afterVoice)"),
    (SEND, "stall retry waits for the configured timeout",
     "ChatOptimizerSettings.timeoutSeconds"),
    (SEND, "error watcher switches model and retries",
     "ChatOptimizer.shared.switchToNextAvailable(sessionId: sid)"),
    (SEND, "error watcher clears the reported banner", "vm.errorMessage = nil"),
    (SEND, "error watcher waits for the turn to settle before retrying", "if !vm.isProcessing { break }"),
    (COMPOSER, "composer has the prompt-rewrite button", "optimizePromptButton"),
    (COMPOSER, "rewrite never overwrites text the user edited mid-flight", "if vm.inputText == original"),
    (COMPOSER, "a failed rewrite surfaces a toast", "systemImage: \"exclamationmark.triangle.fill\""),
    (PICKER, "picker has the speed-test-all button", "Speed-test all models"),
    (PICKER, "manual test covers every account", "includeAllAccounts: true"),
    (PICKER, "rows show a latency badge", "if let text {"),
    (PICKER, "rows show the failure marker as a soft signal", "} else if failed {"),
    (PICKER, "wifi greys out only for provider-delisted models",
     "entry.isUnavailableFromProvider"),
    (OPT, "cache is loaded once at optimizer initialization",
     "UserDefaults.standard.data(forKey: ChatOptimizerSettings.latencyCacheKey)"),
    (OPT, "live results publish the changed entry only", "latencyState.publish(id: id)"),
    (OPT, "badges are backed by stable entry references", "final class ModelLatencyEntryState: ObservableObject"),
    (OPT, "results publish while the run is in flight", "func publish(id: String, seconds: Double?, error: String?, queued: Bool = false)"),
    (OPT, "each completion publishes its own entry", "publish(id: id, seconds: lat, error: nil)"),
    (OPT, "a publish names the entries that changed", "latencyChangedIdsKey"),
    (OPT, "a publish carries the value itself", "latencySecondsKey"),
    (OPT, "the cache is not rewritten per probe", "Persist once at the end"),
    (PICKER, "badge leaves observe only their entry", "@ObservedObject private var state: ModelLatencyEntryState"),
    (PICKER, "API header has a scope-specific speed button", "InstanceSpeedTestButton(instanceId: item.instance.id"),
    (PICKER, "each row has a concrete badge cell", "LatencyBadgeCell(entryId: entry.id)"),
    (PICKER, "the list body reads no speed-test state", "List {\n            if let note = config.headerNote"),
    (OPT, "optimizer owns the stable snapshot", "let latencyState: ModelLatencyState"),
    (PICKER, "progress is isolated in its own button", "private struct SpeedTestButton: View"),
    (PICKER, "progress observes shared run state", "@ObservedObject private var status = ChatOptimizer.shared.speedTestStatus"),
    (SETTINGS, "settings offers the auto-pick switch", "chatOptimizer.autoPickFastest"),
    (SETTINGS, "settings section header is localizable", "Text(\"Chat Auto-Helpers\")"),
    (SETTINGS, "settings offers the auto-switch toggle", "chatOptimizer.autoSwitchUnavailable"),
    (SETTINGS, "settings offers the retry toggle", "chatOptimizer.autoRetryOnTimeout"),
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--static-only", action="store_true")
    args = parser.parse_args()

    ok = True
    add_provider = ROOT / "src/ios/Views/Providers/AddProviderView.swift"
    if add_provider.exists():
        add_provider_text = add_provider.read_text()
        no_ghost_transition = (
            ".transition(.asymmetric(" not in add_provider_text
            and ".animation(.spring(response: 0.35, dampingFraction: 0.88), value: currentStep)" not in add_provider_text
            and ".id(currentStep)" in add_provider_text
        )
        print(("PASS" if no_ghost_transition else "FAIL") + ": provider step changes avoid layered List transitions")
        ok &= no_ghost_transition
    for path, name, needle in CHECKS:
        if not path.exists():
            continue
        text = path.read_text()
        found = needle in text
        print(("PASS" if found else "FAIL") + ": " + name)
        ok &= found

    # [T-speedtest-throttle] A rate limit is an account fact, not a model
    # defect: it must stop the run and must not leave a red cross behind.
    throttle = OPT.read_text()
    checks = [
        ("throttle is recognised", "private static func isThrottle"),
        ("throttle is scoped to one provider", "blockedUntil[providerId]"),
        ("a throttled provider is backed off, not the run", "throttleCooldown"),
        ("throttled results retain a normalized warning", 'latencyState.cache.errors[id] = throttleMessage'),
        ("exhausted-account rows publish throttled status", 'error: "Rate limited"'),
        ("rate-limit badge overrides cached latency", "if isRateLimited {"),
        ("queued retry visibly retains throttle status", "latencyState.enqueue(id: id, error: error)"),
        ("other providers keep going", "return now >= until"),
        ("a throttled row is retried before queued siblings", "queue.insert(original, at: 0)"),
        ("stale throttle errors are cleared before deciding", "cleared \\(staleThrottle.count) stale throttle error"),
        ("manual test uses bounded concurrency", "concurrency: Int = 6"),
        ("each account has its provider-specific concurrency limit", "let accountLimit = min(self.latencyPolicy(for: entry).accountLimit, globalLimit)"),
        ("deadline is passed through to each probe", "timeout: perEntryTimeout"),
        ("reentrant callers join instead of racing", "await withCheckedContinuation { speedTestWaiters.append($0) }"),
    ]
    for name, needle in checks:
        found = needle in throttle or needle in PICKER.read_text()
        print(("PASS" if found else "FAIL") + ": " + name)
        ok &= found

    # Trae: the roster cache must be shared or every request re-fetches it.
    trae_path = ROOT / "src/ios/Providers/Trae/TraeAPI.swift"
    trae_api = trae_path.read_text() if trae_path.exists() else ""
    factory = (ROOT / "src/ios/Providers/LLMProviderFactory.swift").read_text()
    for name, needle in [
        ("Trae roster cache is process-wide", "static let shared = ModelFunctions()"),
        ("Trae provider reuses that cache", "TraeAPI.ModelFunctions.shared"),
        ("roster failure is observable", "func rosterUnavailable(identity: String) -> Bool"),
    ]:
        found = not trae_api or needle in trae_api or needle in factory
        print(("PASS" if found else "FAIL") + ": " + name)
        ok &= found
    if "ModelFunctions()" in factory:
        print("FAIL: a fresh ModelFunctions is still created per provider")
        ok = False

    # Raccoon: the workspace code must travel with every chat request.
    rac_path = ROOT / "src/ios/Providers/Raccoon/RaccoonOAuthManager.swift"
    raccoon_mgr = rac_path.read_text() if rac_path.exists() else ""
    for name, needle in [
        ("org code is persisted", "static let orgCode = \"raccoon-org-code\""),
        ("personal account sends no org header", 'orgCode.lowercased() != "personal"'),
        ("chat carries X-Org-Code", '"X-Org-Code"'),
        ("chat identifies as the desktop client", '"X-Client-Platform"'),
    ]:
        found = not raccoon_mgr or needle in raccoon_mgr or needle in factory
        print(("PASS" if found else "FAIL") + ": " + name)
        ok &= found

    # The soft-fail contract: a probe failure must not mark an entry unavailable.
    # Every user-visible string must be a localizable English key, not a
    # Chinese or other literal the catalog cannot resolve.
    han = re.compile("[\u4e00-\u9fff]")
    code_files = [OPT, PICKER, SETTINGS]
    bad = []
    for f in code_files:
        if not f.exists():
            continue
        for i, line in enumerate(f.read_text().splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("///"):
                continue
            # Prompt bodies handed to the model are data, not UI copy.
            if "你是一个提示词优化助手" in line or "用原文所用的语言" in line:
                continue
            if han.search(line) and ("Text(" in line or "AppLocalized(" in line
                                      or "accessibilityLabel(" in line):
                bad.append(f"{f.name}:{i}: {stripped[:70]}")
    print(("PASS" if not bad else "FAIL") + ": UI strings use localizable English keys")
    for b in bad:
        print("   ", b)
    ok &= not bad

    opt = OPT.read_text()
    softened = "latencyState.cache.unavailable.append" not in opt and "unavailable[id]" not in opt
    print(("PASS" if softened else "FAIL") + ": no speed-test path hard-excludes a model")
    ok &= softened

    picker = PICKER.read_text()
    row = picker.split("private func entryRow(_ entry: ModelEntry)", 1)[1].split(".opacity(disabled", 1)[0]
    trailing = (row.index('Image(systemName: "wifi")')
                < row.index("quickTestButton(entry)")
                < row.index("LatencyBadgeCell(entryId: entry.id)"))
    cell = picker.split("private struct LatencyBadgeCell: View", 1)[1].split("private struct SpeedTestButton", 1)[0]
    reserved = ('ZStack(alignment: .trailing)' in cell and 'Color.clear' in cell
                and '.frame(width: 48, height: 18, alignment: .trailing)' in cell)
    print(("PASS" if trailing and reserved else "FAIL") + ": latency result is rightmost with a concrete fixed slot")
    ok &= trailing and reserved

    if ok:
        command = [sys.executable, str(ROOT / "scripts/test_speedtest_regression.py")]
        if args.static_only:
            command.append("--static-only")
        return subprocess.run(command, check=False).returncode
    print("FAILED")
    return 1


if __name__ == "__main__":
    sys.exit(main())
