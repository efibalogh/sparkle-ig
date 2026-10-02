#!/usr/bin/env python3
"""Strict source/catalog checks for Sparkle internationalization."""

from __future__ import annotations

import math
import plistlib
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src"
BUNDLE = ROOT / "resources" / "Sparkle.bundle"
TRANSLATIONS = ROOT / "translations"
# Sparkle ships only catalogs a native speaker has reviewed. Everything else lives
# in translations/ as a starting point for contributors and as an importable
# language pack, and is held to a looser standard so an unfinished review still
# passes: an incomplete catalog warns, a broken one still fails. Promoting a
# reviewed language is a directory move, so the split is discovered, not listed.
SOURCE_SUFFIXES = {".m", ".mm", ".x", ".xm"}
STRING_RE = re.compile(r'^"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)";\s*$')
NORMAL_CALL_RE = re.compile(r'\bSPKL\(@"([A-Z][A-Z0-9_]*)"\)|\bSPKLC\(@"([A-Z][A-Z0-9_]*)"')
PLURAL_CALL_RE = re.compile(r'\bSPKLP\(@"([A-Z][A-Z0-9_]*)"')
PLACEHOLDER_RE = re.compile(r'%(?!%)(?:\d+\$)?[-+ #0\']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|j|z|t|L)?[@diuoxXfFeEgGaAcCsSp]')
BAD_KEY_RE = re.compile(r'^(?:FEAT_)|VIEWCONTROLLER|(?:^|_)SPK[A-Z0-9_]*CONTROLLER|_[0-9]+$|CONTEXT_[A-F0-9]+$')
UNSAFE_LINE_RE = re.compile(r'(?:isEqualToString|hasPrefix|hasSuffix|imageNamed|instagramIconNamed|menuIconNamed|menuSizedIcon|URLWithString|get(?:Bool|String|Double)Pref|forKey)\s*:\s*SPKL[CP]?\s*\(')
RAW_UI_RE = re.compile(r'(?:\.title|\.text|\.placeholder|\.accessibilityLabel|\.accessibilityHint|\.emptyTitle|\.emptySubtitle|\.infoText|\.successTitle|\.pickerTitle|\.masterTitle|\.finishTitleOverride|\btitle|\bmessage|\bsubtitle|\bheader|\bfooter)\s*[:=]\s*@"[^"\\]*[A-Za-z][^"\\]*"')
RAW_CHROME_RE = re.compile(
    r'SPKMediaChromeBottomBarButtonItem\(\s*@"[^"]+"\s*,\s*@"[^"\\]*[A-Za-z]'
    r'|SPKMediaChromeTopBarButtonItemWithTint\([^;]{0,500}?,\s*@"[^"\\]*[A-Za-z]"\s*\)'
    r'|SPKMediaChromeTopBarMenuButtonItem(?:WithTint)?\([^;]{0,500}?,\s*@"[^"\\]*[A-Za-z]"\s*\)',
    re.DOTALL,
)
# Dictionary literals feed menus, notification rows, progress stages and settings
# groups all over the tweak, so a raw value there is as user-visible as a property.
RAW_DICTIONARY_UI_RE = re.compile(
    r'@"(?:title|label|subtitle|stage|detail|caption|footer|header|message)"\s*:\s*@"[^"\\]*[A-Za-z][^"\\]*"'
)
RAW_ERROR_DESCRIPTION_RE = re.compile(r'NSLocalizedDescriptionKey\s*:\s*@"[^"\\]*[A-Za-z][^"\\]*"')
RAW_BULK_MENU_RE = re.compile(r'SPKBulkActionMenuElementForContext\([^;]{0,900}?,\s*@"[^"\\]*[A-Za-z]"\s*,\s*kSPK', re.DOTALL)
RAW_SELECTOR_UI_RE = re.compile(
    r'(?:WithTitle|updateProgressTitle|\btitle|\bmessage|\bsubtitle|\bplaceholder|\bfooter|\bheader|accessibilityLabel|accessibilityHint)'
    r'\s*:\s*@"[^"\\]*[A-Za-z][^"\\]*"'
)
RAW_FORMATTED_SELECTOR_UI_RE = re.compile(
    r'(?:WithTitle|updateProgressTitle|\btitle|\bmessage|\bsubtitle|\bplaceholder|\bfooter|\bheader|accessibilityLabel|accessibilityHint)'
    r'\s*:\s*\[NSString\s+stringWithFormat\s*:\s*@"[^"\\]*(?<![%A-Za-z])[A-Za-z]{3,}[^"\\]*"'
)
# Brand names, product surfaces and technical tokens that stay in English in every
# locale, so a run made only of these is not evidence of an untranslated string.
UNTRANSLATED_TOKENS = frozenset("""
instagram sparkle ffmpeg ffmpegkit gif gifs reels reel meta ai ios url urls
id ok live story stories http https png jpg jpeg mp4 mp3 m4a hdr sdr qr flex json
zip pdf regram giphy plus app apps api cdn ui hd fps kbps mbps threads igtv boomerang
liquid glass theos core data gallery settings analyzer profile testflight beta home
vault mediavault otf ttf ttc crf explorer hook hooks push instant instants web mobile
face touch s
ryuk ryukgram socuul scinsta instasane zxpluginsinject
""".split())
# English a native reviewer of a shipped catalog chose to keep. Checked per key, so
# the same words left untranslated anywhere else still count against the catalog.
REVIEWED_ENGLISH = {
    "pl": {"ABOUT_INFORMATION_BUNDLE_ID_TITLE", "FONT_STYLE_ULTRA_LIGHT"},
}
# Contributor handles name people, and format specifiers are not words.
NEUTRAL_STRIP_RE = re.compile(r"@[\w.]+|" + PLACEHOLDER_RE.pattern)
# Hyphenated compounds count as one token: German glues "Instagram-Plus-Button"
# into a single legitimate word, and feature names like "view-once" are kept
# verbatim on purpose, so splitting on the hyphen invents English runs that are
# not there.
CARRYOVER_WORD_RE = re.compile(r"[A-Za-z][A-Za-z'\u2019-]*[A-Za-z]|[A-Za-z]")
# "\n" and friends survive as literal backslash escapes in .strings, so strip them
# before tokenizing or the escape letter is counted as an English word.
CARRYOVER_ESCAPE_RE = re.compile(r"\\.")
FORBIDDEN_UI_SHORTHAND_RE = re.compile(r"(?<!%)\bDMs?\b", re.IGNORECASE)


def carryover_words(text):
    return CARRYOVER_WORD_RE.findall(CARRYOVER_ESCAPE_RE.sub(" ", text))
# A translated value must not repeat a long verbatim run of the English source. That
# is the signature of a templated pass that swapped only the leading verb phrase and
# left the rest of the sentence in English.
CARRYOVER_RUN_LENGTH = 4


def english_carryover(value, english_value):
    """Longest verbatim English word-run from english_value present in value, if any."""
    source = carryover_words(english_value)
    if len(source) < CARRYOVER_RUN_LENGTH:
        return None
    haystack = " " + " ".join(word.lower() for word in carryover_words(value)) + " "
    for start in range(len(source) - CARRYOVER_RUN_LENGTH + 1):
        run = source[start:start + CARRYOVER_RUN_LENGTH]
        if all(word.lower() in UNTRANSLATED_TOKENS for word in run):
            continue
        if " " + " ".join(word.lower() for word in run) + " " in haystack:
            return " ".join(run)
    return None


LOCALIZED_CALL_RE = re.compile(r'\bSPKL(?:C|P)?\(\s*@"[A-Z][A-Z0-9_]*"[^)]*\)')
RAW_LITERAL_RE = re.compile(r'@"((?:\\.|[^"\\])*)"')
C_UI_SINKS = {
    "SPKNotify": ((1, "raw user-facing notification title"), (2, "raw user-facing notification subtitle")),
    "SPKNotifyProgress": ((1, "raw user-facing progress title"),),
    "SPKNotificationItem": ((1, "raw user-facing notification row title"),),
    "SPKAudioDMNotify": ((0, "raw user-facing notification title"), (1, "raw user-facing notification subtitle")),
    "SPKFFmpegError": ((0, "raw user-facing FFmpeg error message"),),
    "SPKDownloadError": ((1, "raw user-facing download error message"),),
    "SPKMediaSection": ((0, "raw user-facing media section title"),),
    "SPKTopicSection": ((0, "raw user-facing settings section title"), (2, "raw user-facing settings section footer")),
    "setProgress": ((1, "raw user-facing progress title"),),
    "report": ((1, "raw user-facing progress title"),),
    "fail": ((0, "raw user-facing failure title"), (1, "raw user-facing failure message")),
    "failImport": ((0, "raw user-facing import failure message"),),
}


def source_files() -> list[Path]:
    return sorted(p for p in SOURCE.rglob("*") if p.suffix.lower() in SOURCE_SUFFIXES)


def parse_strings(path: Path) -> tuple[dict[str, str], list[str]]:
    values: dict[str, str] = {}
    errors: list[str] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("/*"):
            continue
        match = STRING_RE.match(line)
        if not match:
            errors.append(f"{path.relative_to(ROOT)}:{line_number}: malformed .strings entry")
            continue
        key, value = match.groups()
        if key in values:
            errors.append(f"{path.relative_to(ROOT)}:{line_number}: duplicate key {key}")
        values[key] = value
    return values, errors


def placeholders(value: str) -> list[str]:
    return [re.sub(r'^%(?:\d+\$)?', "%", token) for token in PLACEHOLDER_RE.findall(value)]


def c_call_arguments(text: str, function_name: str):
    """Yield (offset, arguments) for balanced C-style calls to function_name."""
    call_re = re.compile(rf'\b{re.escape(function_name)}\s*\(')
    for match in call_re.finditer(text):
        arguments: list[str] = []
        argument_start = match.end()
        cursor = argument_start
        paren_depth = bracket_depth = brace_depth = 0
        quote: str | None = None
        escaped = False
        while cursor < len(text):
            character = text[cursor]
            following = text[cursor + 1] if cursor + 1 < len(text) else ""
            if quote:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == quote:
                    quote = None
                cursor += 1
                continue
            if character in ('"', "'"):
                quote = character
                cursor += 1
                continue
            if character == "/" and following == "/":
                newline = text.find("\n", cursor + 2)
                cursor = len(text) if newline < 0 else newline + 1
                continue
            if character == "/" and following == "*":
                comment_end = text.find("*/", cursor + 2)
                cursor = len(text) if comment_end < 0 else comment_end + 2
                continue
            if character == "(":
                paren_depth += 1
            elif character == ")":
                if paren_depth == 0 and bracket_depth == 0 and brace_depth == 0:
                    arguments.append(text[argument_start:cursor].strip())
                    yield match.start(), arguments
                    break
                paren_depth -= 1
            elif character == "[":
                bracket_depth += 1
            elif character == "]":
                bracket_depth -= 1
            elif character == "{":
                brace_depth += 1
            elif character == "}":
                brace_depth -= 1
            elif character == "," and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0:
                arguments.append(text[argument_start:cursor].strip())
                argument_start = cursor + 1
            cursor += 1


def contains_raw_user_text(argument: str) -> bool:
    without_localized_calls = LOCALIZED_CALL_RE.sub("", argument)
    for match in RAW_LITERAL_RE.finditer(without_localized_calls):
        value = match.group(1)
        if not re.search(r"[A-Za-z]", value):
            continue
        before = without_localized_calls[:match.start()].rstrip()
        after = without_localized_calls[match.end():].lstrip()
        if before.endswith("[") and after.startswith("]"):
            continue
        return True
    return False


def ignored_at_offset(text: str, offset: int) -> bool:
    line_start = text.rfind("\n", 0, offset) + 1
    line_end = text.find("\n", offset)
    if line_end < 0:
        line_end = len(text)
    return "SPK_I18N_IGNORE" in text[line_start:line_end]



def discover_catalogs(only_locale: str | None = None):
    """Yield (locale, directory, shipped) for every catalog in the repository."""
    found = []
    for root, shipped in ((BUNDLE, True), (TRANSLATIONS, False)):
        if not root.is_dir():
            continue
        for directory in sorted(root.glob("*.lproj")):
            locale = directory.name[: -len(".lproj")]
            if only_locale and locale != only_locale:
                continue
            found.append((locale, directory, shipped))
    return found


def load_catalog(locale: str, directory: Path, errors: list[str]):
    """Parse one locale's .strings/.stringsdict pair, or None when unusable."""
    strings_path = directory / "Localizable.strings"
    plural_path = directory / "Localizable.stringsdict"
    if not strings_path.exists() or not plural_path.exists():
        errors.append(f"{locale}: missing Localizable.strings or Localizable.stringsdict")
        return None
    values, parse_errors = parse_strings(strings_path)
    errors.extend(parse_errors)
    key_order = list(values)
    if key_order != sorted(key_order):
        first_mismatch = next(
            (key for key, expected in zip(key_order, sorted(key_order)) if key != expected),
            "unknown",
        )
        errors.append(f"{locale}: catalog keys are not sorted near {first_mismatch}")
    try:
        with plural_path.open("rb") as stream:
            plurals = plistlib.load(stream)
    except Exception as exc:
        errors.append(f"{plural_path.relative_to(ROOT)}: invalid plist: {exc}")
        return None
    return values, plurals


def is_language_neutral(value: str) -> bool:
    """A value no translation would change: brand names, tokens, pure punctuation."""
    # A value with no whitespace is a single token - a brand name, an API symbol,
    # an aspect ratio, a unit - not a phrase somebody forgot to translate.
    if value and not any(character.isspace() for character in value):
        return True
    words = carryover_words(NEUTRAL_STRIP_RE.sub(" ", value))
    return not words or all(word.lower() in UNTRANSLATED_TOKENS for word in words)


def check_catalog(locale, values, plurals, english, english_plurals, shipped):
    """Validate one catalog against English.

    Returns (errors, warnings, translated key count).
    """
    errors: list[str] = []
    warnings: list[str] = []
    # Key parity is required of every catalog, shipped or not: a community catalog
    # is distributed as a language pack, so a key it lacks is a string that pack
    # can never translate. Run tools/sync-catalog-keys.py to seed new keys from
    # English. What is downgraded to a warning is only how much has actually been
    # translated, which is a community catalog's normal state of being unfinished.
    incomplete = warnings if not shipped else errors

    translated = 0
    if locale != "en":
        # A key left verbatim in English is untranslated even though it parses, so
        # a freshly seeded catalog must not read as complete. Brand names and
        # technical tokens that no language changes do not count against it.
        untouched = sorted(
            key for key in set(english) & set(values)
            if values[key] == english[key] and not is_language_neutral(english[key])
            and key not in REVIEWED_ENGLISH.get(locale, ())
        )
        translated = len(set(english) & set(values)) - len(untouched)
        if untouched:
            incomplete.append(f"{locale}: {len(untouched)} keys still in English, e.g. {untouched[:5]}")
        missing = sorted(set(english) - set(values))
        stray = sorted(set(values) - set(english))
        if missing:
            plural_suffix = "" if len(missing) == 1 else "s"
            errors.append(f"{locale}: {len(missing)} key{plural_suffix} missing from the catalog, "
                          f"e.g. {missing[:5]}; run tools/sync-catalog-keys.py")
        if stray:
            errors.append(f"{locale}: keys not present in English: {stray[:5]}")
        missing_plural = sorted(set(english_plurals) - set(plurals))
        stray_plural = sorted(set(plurals) - set(english_plurals))
        if missing_plural:
            errors.append(f"{locale}: missing plural keys {missing_plural[:5]}; "
                          f"run tools/generate-i18n-plurals.py")
        if stray_plural:
            errors.append(f"{locale}: plural keys not present in English: {stray_plural[:5]}")

    for key, value in values.items():
        if BAD_KEY_RE.search(key):
            errors.append(f"{locale}: non-semantic key {key}")
        shorthand = FORBIDDEN_UI_SHORTHAND_RE.search(value)
        if shorthand:
            errors.append(f"{locale}: forbidden user-facing shorthand {shorthand.group(0)!r} in {key}")
        if key in english and placeholders(value) != placeholders(english[key]):
            errors.append(f"{locale}: placeholder mismatch for {key}: {placeholders(value)} != {placeholders(english[key])}")
        if locale != "en" and key in english and value != english[key]:
            carried = english_carryover(value, english[key])
            if carried:
                incomplete.append(f"{locale}: untranslated English carried into {key}: \"{carried}...\"")

    for key, entry in plurals.items():
        rule = entry.get("count", {}) if isinstance(entry, dict) else {}
        if entry.get("NSStringLocalizedFormatKey") != "%#@count@" or rule.get("NSStringFormatSpecTypeKey") != "NSStringPluralRuleType":
            errors.append(f"{locale}: invalid plural definition for {key}")
        if "other" not in rule:
            errors.append(f"{locale}: plural {key} lacks an other form")
        for category, value in rule.items():
            if category.startswith("NSString"):
                continue
            if len(placeholders(str(value))) != 1:
                errors.append(f"{locale}: plural {key}/{category} must contain exactly one numeric placeholder")

    return errors, warnings, translated


def main(only_locale: str | None = None, emit_table: bool = False) -> int:
    errors: list[str] = []
    warnings: list[str] = []
    normal_uses: Counter[str] = Counter()
    plural_uses: Counter[str] = Counter()

    for path in source_files():
        text = path.read_text(encoding="utf-8")
        for match in NORMAL_CALL_RE.finditer(text):
            normal_uses[match.group(1) or match.group(2)] += 1
        for match in PLURAL_CALL_RE.finditer(text):
            plural_uses[match.group(1)] += 1
        for pattern, description in (
            (RAW_CHROME_RE, "raw user-facing chrome label"),
            (RAW_BULK_MENU_RE, "raw user-facing bulk-menu title"),
            (RAW_SELECTOR_UI_RE, "raw user-facing selector argument"),
            (RAW_FORMATTED_SELECTOR_UI_RE, "raw formatted user-facing selector argument"),
            (RAW_DICTIONARY_UI_RE, "raw user-facing dictionary value"),
            (RAW_ERROR_DESCRIPTION_RE, "raw user-facing error description"),
        ):
            for match in pattern.finditer(text):
                if "SPK_I18N_IGNORE" not in match.group(0) and not ignored_at_offset(text, match.start()):
                    line_number = text.count("\n", 0, match.start()) + 1
                    errors.append(f"{path.relative_to(ROOT)}:{line_number}: {description}")
        for function_name, positions in C_UI_SINKS.items():
            for offset, arguments in c_call_arguments(text, function_name):
                for position, description in positions:
                    if position < len(arguments) and contains_raw_user_text(arguments[position]):
                        line_number = text.count("\n", 0, offset) + 1
                        if not ignored_at_offset(text, offset):
                            errors.append(f"{path.relative_to(ROOT)}:{line_number}: {description}")
        for line_number, line in enumerate(text.splitlines(), 1):
            if UNSAFE_LINE_RE.search(line):
                errors.append(f"{path.relative_to(ROOT)}:{line_number}: localized value used as an internal identifier or comparison")
            if RAW_UI_RE.search(line) and "SPK_I18N_IGNORE" not in line and '@"\\u' not in line:
                errors.append(f"{path.relative_to(ROOT)}:{line_number}: raw user-facing UI string")

    english_directory = BUNDLE / "en.lproj"
    loaded = load_catalog("en", english_directory, errors)
    english, english_plurals = loaded if loaded else ({}, {})
    errors.extend(check_catalog("en", english, english_plurals, english, english_plurals, shipped=True)[0])

    coverage: list[tuple[str, int]] = []
    for locale, directory, shipped in discover_catalogs(only_locale):
        if locale == "en":
            continue
        loaded = load_catalog(locale, directory, errors)
        if not loaded:
            continue
        values, plurals = loaded
        catalog_errors, catalog_warnings, translated = check_catalog(
            locale, values, plurals, english, english_plurals, shipped=shipped
        )
        errors.extend(catalog_errors)
        warnings.extend(catalog_warnings)
        if english:
            coverage.append((locale, math.floor(100 * translated / len(english))))

    english = english or {}
    english_plurals = english_plurals or {}
    missing = sorted(set(normal_uses) - set(english))
    unused = sorted(set(english) - set(normal_uses))
    missing_plural = sorted(set(plural_uses) - set(english_plurals))
    unused_plural = sorted(set(english_plurals) - set(plural_uses))
    if missing:
        errors.append(f"source keys missing from catalogs: {missing[:20]}")
    if unused:
        errors.append(f"unused catalog keys: {unused[:20]} ({len(unused)} total)")
    if missing_plural:
        errors.append(f"source plural keys missing from stringsdict: {missing_plural}")
    if unused_plural:
        errors.append(f"unused plural keys: {unused_plural}")

    if warnings:
        print("i18n lint warnings:", file=sys.stderr)
        for warning in warnings:
            print(f"  - {warning}", file=sys.stderr)
    if errors:
        print("i18n lint failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    shipped = ", ".join(locale for locale, _, is_shipped in discover_catalogs() if is_shipped)
    print(f"i18n lint passed: {len(english)} strings, {len(english_plurals)} plural keys; shipped: {shipped}")
    shipped_codes = {locale for locale, _, is_shipped in discover_catalogs() if is_shipped}
    community = [(locale, percent) for locale, percent in coverage if locale not in shipped_codes]
    if community:
        print("community catalogs: " + ", ".join(f"{locale} {percent}%" for locale, percent in community))
    if emit_table:
        print()
        print("| Language | Coverage | Ships in Sparkle |")
        print("| --- | --- | --- |")
        print(f"| en | 100% | yes |")
        for locale, percent in coverage:
            ships = "yes" if any(l == locale and s for l, _, s in discover_catalogs()) else "not yet"
            print(f"| {locale} | {percent}% | {ships} |")
    return 0


if __name__ == "__main__":
    arguments = sys.argv[1:]
    table = "--table" in arguments
    arguments = [argument for argument in arguments if argument != "--table"]
    locale_only = None
    if arguments and arguments[0] == "--locale":
        if len(arguments) < 2:
            print("usage: lint-i18n.py [--locale <code>] [--table]", file=sys.stderr)
            raise SystemExit(2)
        locale_only = arguments[1]
    raise SystemExit(main(locale_only, table))
