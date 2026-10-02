#!/usr/bin/env python3
"""Build catalog.json from a published release's language-pack assets.

The catalog is what the in-app "Download a language" screen reads, and what the updater compares
an installed pack against. Every row carries the asset's real sha256, so a pack can only install
if the bytes match what this script measured, and an installed pack is "out of date" precisely
when its recorded hash stops matching the row here.

Run it after publishing the Sparkle-<code>.zip assets for a release:

    tools/generate-catalog.py v1.3.1

Coverage is measured against that release's own en.lproj (read from the git tag), not the working
tree, so a pack that was complete when published keeps saying so while main moves ahead of it.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import urllib.error
import urllib.request
import zipfile
from io import BytesIO
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = "efibalogh/sparkle-ig"
ASSET_URL = "https://github.com/{repo}/releases/download/{tag}/Sparkle-{code}.zip"

# Endonyms shown in the picker; the app falls back to NSLocale for anything absent.
ENDONYMS = {
    "ar": "العربية", "de": "Deutsch", "el": "Ελληνικά", "es-ES": "Español",
    "fr": "Français", "hi": "हिन्दी", "it": "Italiano", "ja": "日本語",
    "ko": "한국어", "lt": "Lietuvių", "pt-BR": "Português (Brasil)", "ro": "Română",
    "ru": "Русский", "tr": "Türkçe", "uk": "Українська", "vi": "Tiếng Việt",
    "zh-Hans": "简体中文", "zh-Hant": "繁體中文",
    "es-419": "Español (Latinoamérica)", "fa": "فارسی", "fil": "Filipino",
    "gsw-BE": "Bärndütsch", "id": "Bahasa Indonesia", "pl": "Polski", "th": "ไทย",
}
NAMES = {
    "ar": "Arabic", "de": "German", "el": "Greek", "es-ES": "Spanish",
    "fr": "French", "hi": "Hindi", "it": "Italian", "ja": "Japanese",
    "ko": "Korean", "lt": "Lithuanian", "pt-BR": "Portuguese (Brazil)", "ro": "Romanian",
    "ru": "Russian", "tr": "Turkish", "uk": "Ukrainian", "vi": "Vietnamese",
    "zh-Hans": "Chinese (Simplified)", "zh-Hant": "Chinese (Traditional)",
    "es-419": "Spanish (Latin America)", "fa": "Persian", "fil": "Filipino",
    "gsw-BE": "Swiss German (Bern)", "id": "Indonesian", "pl": "Polish", "th": "Thai",
}


def parse_strings(blob: bytes) -> dict:
    """A .strings file may be old-style text or a binary plist; plutil reads both, plistlib only one."""
    converted = subprocess.run(["plutil", "-convert", "json", "-o", "-", "-"],
                               input=blob, capture_output=True, check=True).stdout
    return json.loads(converted)


def english_keys_at(tag: str) -> set[str]:
    """The English catalog as it shipped in `tag`, so coverage is measured against its own release."""
    blob = subprocess.run(
        ["git", "show", f"{tag}:resources/Sparkle.bundle/en.lproj/Localizable.strings"],
        cwd=ROOT, capture_output=True, check=True,
    ).stdout
    return set(parse_strings(blob))


def local_codes() -> list[str]:
    """Languages that have a catalog in the tree, which is what gets published as packs."""
    codes = [p.name[: -len(".lproj")] for p in (ROOT / "translations").glob("*.lproj")]
    return sorted(codes)


def pack_row(tag: str, code: str, english: set[str]) -> dict | None:
    url = ASSET_URL.format(repo=REPO, tag=tag, code=code)
    try:
        data = urllib.request.urlopen(url, timeout=60).read()
    except urllib.error.HTTPError as exc:
        print(f"  {code}: no asset published for {tag} ({exc.code})", file=sys.stderr)
        return None

    with zipfile.ZipFile(BytesIO(data)) as archive:
        names = [n for n in archive.namelist() if n.endswith("Localizable.strings")]
        if not names:
            print(f"  {code}: archive carries no Localizable.strings", file=sys.stderr)
            return None
        keys = set(parse_strings(archive.read(names[0])))

    covered = len(english & keys)
    coverage = round(100 * covered / len(english)) if english else 0
    return {
        "code": code,
        "name": NAMES.get(code, code),
        "endonym": ENDONYMS.get(code, code),
        "url": url,
        "sha256": hashlib.sha256(data).hexdigest(),
        "bytes": len(data),
        "coverage": coverage,
    }


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    tag = sys.argv[1]
    english = english_keys_at(tag)
    print(f"{tag}: English baseline has {len(english)} keys")

    packs = []
    for code in local_codes():
        row = pack_row(tag, code, english)
        if row:
            packs.append(row)
            print(f"  {code}: {row['coverage']}%, {row['bytes']} bytes")

    if not packs:
        print("no assets found — was the release published?", file=sys.stderr)
        return 1

    out = ROOT / "catalog.json"
    out.write_text(json.dumps({"version": 1, "packs": packs}, ensure_ascii=False, indent=2) + "\n",
                   encoding="utf-8")
    print(f"wrote {out.relative_to(ROOT)} with {len(packs)} pack(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
