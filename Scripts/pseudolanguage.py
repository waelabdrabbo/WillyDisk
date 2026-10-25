#!/usr/bin/env python3
"""Regenerate the doubled-length pseudolanguage in the string catalog.

`en-XA` is generated, not written. Its accented, padded values are what the
offscreen renderer uses to expose truncation, so every English source string
must have one and it must follow the English value. This script reads the
catalog, rewrites only the `en-XA` localizations from the English ones, and
leaves `en` and `ar` untouched.

Usage:
    python3 Scripts/pseudolanguage.py            # rewrite the catalog
    python3 Scripts/pseudolanguage.py --check    # fail if any value is stale

Run it after adding or changing an English or Arabic entry, then run
`bash Scripts/localize.sh` to compile the catalog into the shipped `.lproj`
tables.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Sources/DiskLocalization/Localizable.xcstrings"

# A printf token is copied through untouched; only the prose around it is
# accented and padded.
SPEC = re.compile(
    r"%(?:%|[-+ 0#']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDuUxXoOfeEgGcCsSpaAF])"
)

ACCENTS = {}
for plain, accented in [
    ("a", "á"), ("b", "ƀ"), ("c", "ç"), ("d", "ð"), ("e", "é"), ("f", "ƒ"),
    ("g", "ĝ"), ("h", "ĥ"), ("i", "í"), ("j", "ĵ"), ("k", "ķ"), ("l", "ļ"),
    ("m", "ɱ"), ("n", "ñ"), ("o", "ö"), ("p", "þ"), ("q", "ǫ"), ("r", "ŕ"),
    ("s", "š"), ("t", "ŧ"), ("u", "ú"), ("v", "ṽ"), ("w", "ŵ"), ("x", "ẋ"),
    ("y", "ý"), ("z", "ž"),
]:
    ACCENTS[plain] = accented
    ACCENTS[plain.upper()] = accented.upper()


def pseudolanguage(value: str) -> str:
    """Accent the prose and pad it to roughly twice the English length.

    A multiline value is only bracketed: its length already exercises the
    layout, and padding blank lines would make a sheet look broken rather than
    long.
    """
    output = []
    index = 0
    while index < len(value):
        match = SPEC.match(value, index)
        if match:
            output.append(match.group(0))
            index = match.end()
            continue
        character = value[index]
        output.append(ACCENTS.get(character, character))
        index += 1
    accented = "".join(output)
    if "\n" in value:
        return f"[{accented}]"
    target = max(len(value) * 2, len(accented) + 6)
    padding = "·" * max(0, target - len(accented) - 2)
    return f"[{accented}{padding}]"


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def generated_localization(english: dict) -> dict | None:
    variations = english.get("variations", {}).get("plural")
    if isinstance(variations, dict):
        categories = {}
        for category, entry in variations.items():
            value = entry.get("stringUnit", {}).get("value")
            if not isinstance(value, str):
                return None
            categories[category] = unit(pseudolanguage(value))
        return {"variations": {"plural": categories}}
    value = english.get("stringUnit", {}).get("value")
    if not isinstance(value, str):
        return None
    return unit(pseudolanguage(value))


def main() -> int:
    check = "--check" in sys.argv[1:]
    unknown = [arg for arg in sys.argv[1:] if arg != "--check"]
    if unknown:
        print(f"usage: python3 {Path(__file__).name} [--check]", file=sys.stderr)
        return 2
    if not CATALOG.exists():
        print(f"error: missing catalog at {CATALOG}", file=sys.stderr)
        return 1

    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    strings = catalog.get("strings", {})
    stale: list[str] = []
    missing_english: list[str] = []
    for key, entry in strings.items():
        localizations = entry.setdefault("localizations", {})
        english = localizations.get("en")
        if not isinstance(english, dict):
            missing_english.append(key)
            continue
        generated = generated_localization(english)
        if generated is None:
            missing_english.append(key)
            continue
        if check:
            if localizations.get("en-XA") != generated:
                stale.append(key)
        else:
            localizations["en-XA"] = generated

    if missing_english:
        print(
            f"error: {len(missing_english)} key(s) have no usable English value: "
            + ", ".join(repr(key) for key in missing_english[:5]),
            file=sys.stderr,
        )
        return 1

    if check:
        if stale:
            print(
                f"error: {len(stale)} pseudolanguage value(s) are stale: "
                + ", ".join(repr(key) for key in stale[:5]),
                file=sys.stderr,
            )
            print("       Run: python3 Scripts/pseudolanguage.py", file=sys.stderr)
            return 1
        print("Pseudolanguage values are current.")
        return 0

    CATALOG.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"Regenerated {len(strings)} pseudolanguage values in {CATALOG.relative_to(ROOT)}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
