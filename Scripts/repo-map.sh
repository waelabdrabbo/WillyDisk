#!/usr/bin/env bash
#
# repo-map.sh — print a one-screen inventory of the working tree.
#
# A fresh session should be able to orient with one cheap command. Globbing the
# tree reaches ignored paths and reports thousands of .build byproducts, so this
# lists tracked files only, plus line counts by area, the largest sources, and the
# top-level declaration in each source file.
#
# Usage:
#   bash Scripts/repo-map.sh            # inventory
#   bash Scripts/repo-map.sh --types    # also list each file's top-level declaration

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TEXT_RE='\.(swift|sh|md|json|yml|yaml)$'

echo "== tracked files =="
git ls-files

echo
echo "== size by area (text files) =="
printf '%-24s %6s %8s\n' area files lines
for d in Sources/DiskCore Sources/DiskUI Sources/WillyDiskApp Tests Scripts docs; do
  files=$(git ls-files "$d" | grep -E "$TEXT_RE" | wc -l | tr -d ' ')
  lines=$(git ls-files "$d" | grep -E "$TEXT_RE" | tr '\n' '\0' | xargs -0 wc -l 2>/dev/null | tail -1 | awk '{print $1}')
  printf '%-24s %6s %8s\n' "$d" "$files" "${lines:-0}"
done

echo
echo "== largest sources =="
git ls-files '*.swift' | tr '\n' '\0' | xargs -0 wc -l 2>/dev/null | sort -rn | sed -n '2,11p'

if [[ "${1:-}" == "--types" ]]; then
  echo
  echo "== top-level declarations =="
  git ls-files '*.swift' | while read -r f; do
    decl=$(grep -nE '^(public |final |struct |enum |actor |class |extension |@main|@MainActor)' "$f" | head -1 | cut -d: -f2- || true)
    printf '%s: %s\n' "$f" "${decl:-—}"
  done
fi

echo
echo "== working tree =="
git status --short
