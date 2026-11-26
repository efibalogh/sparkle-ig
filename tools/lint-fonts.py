#!/usr/bin/env python3
"""Guards Sparkle UI against fixed font sizes.

Sparkle text follows the user's text size through SPKFont (src/Shared/UI/SPKFont.h).
A fixed `systemFontOfSize:` or an uncapped `preferredFontForTextStyle:` makes a
screen look out of place next to scaled text, so both are errors outside the files
that are allowed to build fonts directly.

Files still being migrated are listed with their current count in
tools/font-lint-baseline.txt. A file may not exceed its baseline, and a file that
drops below it fails until the baseline is lowered with --update-baseline, so the
list only ever shrinks.

Usage:
  tools/lint-fonts.py                     check, exit nonzero on any error
  tools/lint-fonts.py --update-baseline   lower baseline counts to the current ones
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src"
BASELINE = ROOT / "tools" / "font-lint-baseline.txt"
SOURCE_SUFFIXES = {".m", ".mm", ".x", ".xm"}

# Files that build fonts from raw sizes on purpose: the helper itself, the custom
# font swap, and the font picker, whose previews show a face at a set size.
ALLOWED = {
    "src/Shared/UI/SPKFont.m",
    "src/Features/Interface/CustomFont.x",
    "src/Shared/Fonts/SPKFontManager.m",
    "src/Settings/SPKFontPickerViewController.m",
}

# A line may opt out when the text is drawn into an image or media rather than
# shown as UI. The marker must say why after the colon.
OPT_OUT_RE = re.compile(r"//\s*spk-font-fixed:\s*\S")

FIXED_RE = re.compile(
    r"\b(?:systemFontOfSize|boldSystemFontOfSize|italicSystemFontOfSize"
    r"|monospacedSystemFontOfSize|monospacedDigitSystemFontOfSize"
    r"|preferredFontForTextStyle|fontWithSize)\s*:"
)
LINE_COMMENT_RE = re.compile(r"(?<!:)//.*$")


def strip_block_comments(text: str) -> str:
    # Keep newlines so line numbers stay right.
    return re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.DOTALL)


def scan() -> dict[str, list[int]]:
    hits: dict[str, list[int]] = {}
    for path in sorted(SOURCE.rglob("*")):
        if path.suffix not in SOURCE_SUFFIXES or not path.is_file():
            continue
        rel = path.relative_to(ROOT).as_posix()
        if rel in ALLOWED:
            continue
        text = strip_block_comments(path.read_text(encoding="utf-8", errors="replace"))
        for number, line in enumerate(text.splitlines(), 1):
            if OPT_OUT_RE.search(line):
                continue
            code = LINE_COMMENT_RE.sub("", line)
            count = len(FIXED_RE.findall(code))
            if count:
                hits.setdefault(rel, []).extend([number] * count)
    return hits


def read_baseline() -> dict[str, int]:
    baseline: dict[str, int] = {}
    if not BASELINE.exists():
        return baseline
    for raw in BASELINE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        count, rel = line.split(None, 1)
        baseline[rel] = int(count)
    return baseline


def write_baseline(baseline: dict[str, int]) -> None:
    header = (
        "# Files still on fixed font sizes, with how many each may hold.\n"
        "# Lower only, via tools/lint-fonts.py --update-baseline. Never add a file.\n"
    )
    body = "".join(f"{count} {rel}\n" for rel, count in sorted(baseline.items()))
    BASELINE.write_text(header + body, encoding="utf-8")


def main(argv: list[str]) -> int:
    hits = scan()
    baseline = read_baseline()

    if "--update-baseline" in argv:
        lowered = {rel: min(count, len(hits.get(rel, []))) for rel, count in baseline.items()}
        lowered = {rel: count for rel, count in lowered.items() if count > 0}
        write_baseline(lowered)
        print(f"baseline: {len(lowered)} files, {sum(lowered.values())} fixed sizes left")
        return 0

    errors: list[str] = []
    for rel, lines in sorted(hits.items()):
        allowed = baseline.get(rel, 0)
        if len(lines) > allowed:
            where = ", ".join(str(n) for n in sorted(set(lines)))
            if allowed:
                errors.append(f"{rel}: {len(lines)} fixed font sizes, baseline allows {allowed} (lines {where})")
            else:
                errors.append(f"{rel}: fixed font size, use SPKFont (lines {where})")
    for rel, allowed in sorted(baseline.items()):
        current = len(hits.get(rel, []))
        if current < allowed:
            errors.append(f"{rel}: down to {current} from baseline {allowed}, run tools/lint-fonts.py --update-baseline")

    left = sum(min(len(hits.get(rel, [])), count) for rel, count in baseline.items())
    for error in errors:
        print(f"error: {error}")
    print(f"fonts: {len(errors)} errors, {left} fixed sizes left in {len(baseline)} baseline files")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
