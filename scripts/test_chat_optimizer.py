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
    (OPT, "failed probe records an error", "updated.errors[id] = probe.error"),
    (OPT, "speed-test failure never hard-excludes a model",
     "updated.unavailable.removeAll { $0 == id }"),
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
    (PICKER, "rows show a latency badge", "latencyBadgeText(for: entry)"),
    (PICKER, "rows show the failure marker as a soft signal", "latencyFailed(for: entry)"),
    (PICKER, "wifi greys out only for provider-delisted models",
     "entry.isUnavailableFromProvider"),
    (PICKER, "cache is read from UserDefaults, not the MainActor",
     "UserDefaults.standard.data(forKey: key)"),
    (PICKER, "latency results repaint the list", "latencyTick &+= 1"),
    (SETTINGS, "settings offers the auto-pick switch", "chatOptimizer.autoPickFastest"),
    (SETTINGS, "settings section header is localizable", "Text(\"Chat Auto-Helpers\")"),
    (SETTINGS, "settings offers the auto-switch toggle", "chatOptimizer.autoSwitchUnavailable"),
    (SETTINGS, "settings offers the retry toggle", "chatOptimizer.autoRetryOnTimeout"),
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--static-only", action="store_true")
    parser.parse_args()

    ok = True
    for path, name, needle in CHECKS:
        text = path.read_text() if path.exists() else ""
        found = needle in text
        print(("PASS" if found else "FAIL") + ": " + name)
        ok &= found

    # The soft-fail contract: a probe failure must not mark an entry unavailable.
    # Every user-visible string must be a localizable English key, not a
    # Chinese or other literal the catalog cannot resolve.
    han = re.compile("[\u4e00-\u9fff]")
    code_files = [OPT, COMPOSER, PICKER, SETTINGS, SEND]
    bad = []
    for f in code_files:
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
    softened = "updated.unavailable.append" not in opt and "unavailable[id]" not in opt
    print(("PASS" if softened else "FAIL") + ": no speed-test path hard-excludes a model")
    ok &= softened

    print("SKIP: Swift runtime tests (static checks only)" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
