#!/usr/bin/env python3
"""Static wiring checks for the Quick Test agent-shaped fallback.

The runtime Swift test suite requires Xcode, so these checks assert the exact
source seams that make the fallback real: the plain probe is retried only on
failure, the retry uses AgentProvider with a one-off session, and it reads the
agent stream rather than the lightweight completion shape Raccoon rejects.
"""
from pathlib import Path
import argparse
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/ios/Views/Providers/ModelQuickTestSheet.swift"

FALLBACK_WIRING = [
    ("plain probe failure is caught and retried", "retrying via agent path"),
    ("retry runs the agent-shaped probe", "performAgentTextProbe(entry: entry)"),
    ("agent probe uses the shared agent factory", "AIChatViewModel.makeAgentProvider("),
    ("agent probe gets a one-off session", "OpenCodeChannel.oneOffSessionId()"),
    ("agent probe drives the agent stream", "provider.streamAgentMessageClamped("),
    ("agent probe does not request thinking", "thinkingLevel: .off"),
    ("text delta is accumulated", "case .textDelta(let delta) = event"),
]

FORBIDDEN = [
    ("fallback does not use streamMessage", "streamMessage", "performAgentTextProbe"),
    ("fallback does not use sendMessage", "sendMessage", "performAgentTextProbe"),
]


def check_source() -> bool:
    text = SOURCE.read_text()
    ok = True
    for name, needle in FALLBACK_WIRING:
        found = needle in text
        print(("PASS" if found else "FAIL") + ": " + name)
        ok &= found
    for name, needle, func in FORBIDDEN:
        begin = text.find("private static func " + func)
        end = text.find("\n    }", begin)
        body = text[begin:end] if begin >= 0 and end >= 0 else ""
        found = needle not in body
        print(("PASS" if found else "FAIL") + ": " + name)
        ok &= found
    return ok


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--static-only", action="store_true")
    parser.parse_args()
    ok = check_source()
    print("SKIP: Swift runtime tests (static checks only)" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
