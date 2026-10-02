#!/usr/bin/env python3
"""Bring every community catalog to key parity with English.

The catalogs in translations/ do not ship with Sparkle, but they are distributed as
language packs, so a key missing from one is a string the pack cannot translate
at all. New keys are inserted with the English value: the pack stays complete,
and the linter reports the entry as still-in-English, which is the to-do list a
translator works from.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGLISH = ROOT / "resources" / "Sparkle.bundle" / "en.lproj" / "Localizable.strings"
TRANSLATIONS = ROOT / "translations"
# Snapshot of English as of the last sync. Without it a seeded placeholder goes
# stale the moment the English wording is revised: the key is present, so nothing
# reports it, and every pack keeps showing text Sparkle no longer says.
BASELINE = TRANSLATIONS / ".english-baseline.strings"
ENTRY_RE = re.compile(r'^"((?:\\.|[^"\\])*)"\s*=\s*.*;\s*$')


def entries(path: Path) -> dict[str, str]:
    found = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = ENTRY_RE.match(line)
        if match:
            found[match.group(1)] = line
    return found


def main() -> int:
    english = entries(ENGLISH)
    if not english:
        print(f"No English catalog at {ENGLISH.relative_to(ROOT)}", file=sys.stderr)
        return 1

    baseline = entries(BASELINE) if BASELINE.exists() else {}

    changed = 0
    for catalog in sorted(TRANSLATIONS.glob("*.lproj/Localizable.strings")):
        locale = catalog.parent.name[: -len(".lproj")]
        existing = entries(catalog)
        missing = sorted(set(english) - set(existing))
        stray = sorted(set(existing) - set(english))
        # A value still identical to the English it was seeded from was never
        # translated, so it follows the English wording. A real translation differs
        # from the baseline and is left alone.
        stale = sorted(
            key for key in set(english) & set(existing) & set(baseline)
            if existing[key] == baseline[key] and english[key] != baseline[key]
        )
        if not missing and not stray and not stale:
            continue

        for key in stray:
            del existing[key]
        for key in set(missing) | set(stale):
            existing[key] = english[key]

        # Every catalog is sorted by key, which is also what the linter enforces.
        catalog.write_text("\n".join(existing[key] for key in sorted(existing)) + "\n", encoding="utf-8")
        changed += 1
        report = []
        if missing:
            report.append(f"+{len(missing)} from English")
        if stale:
            report.append(f"~{len(stale)} refreshed to reworded English")
        if stray:
            report.append(f"-{len(stray)} no longer in English")
        print(f"{locale}: {', '.join(report)}")

    BASELINE.write_text("\n".join(english[key] for key in sorted(english)) + "\n", encoding="utf-8")
    print(f"{changed} catalog(s) updated" if changed else "All catalogs already match English")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
