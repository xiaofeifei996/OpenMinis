#!/usr/bin/env python3
"""Find ProviderType switches that are neither exhaustive nor defaulted.

A missing case in one of these is a hard compile error ("switch must be
exhaustive"), and a full iOS build costs ~40 minutes, so this reports all of
them in one pass. It understands:

  * switches over `providerType` / `providerKind` / `type` / `selectedType`
  * `case .a, .b:` spread across continuation lines
  * `if case` and `guard case` (not reported — they need no exhaustiveness)

MinisTests are skipped: the standalone tests carry their own mirror of
ProviderType, so an exhaustiveness check against the real enum does not apply.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TYPES = os.path.join(ROOT, 'src/ios/Providers/ProviderTypes.swift')


def provider_cases():
    src = open(TYPES, encoding='utf-8').read()
    body = src.split('enum ProviderType', 1)[1]
    body = body.split('case unsupported', 1)[0] + 'case unsupported'
    return set(re.findall(r'^\s*case (\w+)$', body, re.M))


def collect_body(lines, start):
    """Lines of the switch starting at `start`, to its matching close brace."""
    indent = len(lines[start]) - len(lines[start].lstrip())
    close_pat = re.compile(r'^\s{0,%d}\}' % indent)
    body = [lines[start]]
    for j in range(start + 1, min(start + 400, len(lines))):
        seg = lines[j]
        if close_pat.match(seg) and seg.strip() == '}':
            break
        body.append(seg)
    return body


def case_labels(lines):
    """Every `.case` label in a switch body, joining multi-line case headers."""
    labels = set()
    for k, seg in enumerate(lines):
        m = re.match(r'^\s*case\s+(.*)$', seg)
        if not m:
            continue
        text = m.group(1)
        n = k + 1
        while ':' not in text and n < len(lines):
            nxt = lines[n]
            if re.match(r'^\s*case\s', nxt) or nxt.strip() == '}':
                break
            text += ' ' + nxt.strip()
            n += 1
        for label in text.split(':')[0].split(','):
            label = label.strip()
            if label.startswith('.'):
                labels.add(label[1:])
    return labels


def main():
    cases = provider_cases()
    if not cases:
        print('could not read ProviderType cases')
        return 2
    print(f'ProviderType cases ({len(cases)}): {sorted(cases)}')

    problems = []
    for dirpath, _, filenames in os.walk(os.path.join(ROOT, 'src/ios')):
        if 'MinisTests' in dirpath:
            continue
        for fn in filenames:
            if not fn.endswith('.swift'):
                continue
            path = os.path.join(dirpath, fn)
            lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
            for i, line in enumerate(lines):
                if not re.search(r'\bswitch\s+.*(providerType|providerKind|\btype\b|selectedType)', line):
                    continue
                body = collect_body(lines, i)
                text = '\n'.join(body)
                if re.search(r'^\s*default\s*:', text, re.M):
                    continue
                present = case_labels(body)
                if len(present & cases) < 3:
                    # Not a ProviderType switch (some other `type` enum).
                    continue
                missing = cases - present
                if missing:
                    problems.append((os.path.relpath(path, ROOT), i + 1, sorted(missing)))

    if problems:
        for rel, ln, missing in problems:
            print(f'{rel}:{ln}  missing: {", ".join(missing)}')
        print(f'\n{len(problems)} switch(es) need attention')
        return 1

    print('OK — every ProviderType switch is exhaustive')
    return 0


if __name__ == '__main__':
    sys.exit(main())
