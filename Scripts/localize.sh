#!/usr/bin/env bash
#
# localize.sh — compile the string catalog into the `.lproj` resources SwiftPM
# ships, and check that the committed resources are current.
#
# Usage:
#   bash Scripts/localize.sh            # regenerate Sources/DiskLocalization/Resources
#   bash Scripts/localize.sh --check    # fail if the committed output is stale
#
# `Localizable.xcstrings` is the source of truth for every user-visible string.
# SwiftPM does not compile a catalog without asking `xcstringstool` to derive
# Swift symbols, and the catalog's format-only keys cannot all be symbols, so
# the compiled `Localizable.strings`/`.stringsdict` files are committed beside
# the catalog's resources. Re-run this after editing the catalog.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/Sources/DiskLocalization/Localizable.xcstrings"
RESOURCES="$ROOT/Sources/DiskLocalization/Resources"
CHECK=0

if [[ "${1:-}" == "--check" ]]; then
  CHECK=1
elif [[ $# -gt 0 ]]; then
  echo "usage: bash Scripts/localize.sh [--check]" >&2
  exit 2
fi

if [[ ! -f "$CATALOG" ]]; then
  echo "error: missing string catalog at $CATALOG" >&2
  exit 1
fi
if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find xcstringstool >/dev/null 2>&1; then
  echo "error: xcstringstool is not available; install Xcode to compile the catalog." >&2
  exit 1
fi

compile_into() {
  local output="$1"
  mkdir -p "$output"
  xcrun xcstringstool compile --output-directory "$output" "$CATALOG"
  # The tool copies its input beside the products; that copy is not a resource
  # and must never be processed a second time.
  rm -f "$output/Localizable.xcstrings"
  for language in en ar en-XA; do
    if [[ ! -f "$output/$language.lproj/Localizable.strings" ]]; then
      echo "error: $language.lproj/Localizable.strings was not written" >&2
      exit 1
    fi
  done
}

if [[ "$CHECK" == 1 ]]; then
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  compile_into "$scratch"
  if ! diff -r "$RESOURCES" "$scratch" >/dev/null; then
    echo "error: the compiled localization resources are stale." >&2
    echo "       Run: bash Scripts/localize.sh" >&2
    diff -r "$RESOURCES" "$scratch" | head -40 >&2
    exit 1
  fi
  echo "Localization resources are current."
  exit 0
fi

rm -rf "$RESOURCES"/en.lproj "$RESOURCES"/ar.lproj "$RESOURCES"/en-XA.lproj
compile_into "$RESOURCES"
echo "Compiled $(find "$RESOURCES" -name '*.lproj' | wc -l | tr -d ' ') languages into $RESOURCES"
