#!/usr/bin/env bash
# Keeps the committed diagram SVGs honest.
#
# Diagrams are written as .d2 and rendered to SVG at build time, but the SVG is
# committed too — GitHub renders it without a build, and the PDF embeds it. That
# only works if the two never drift, which is what this checks:
#
#   * every .d2 renders, and matches its committed .svg
#   * every diagram referenced by a page exists
#   * basenames are unique across directories, because the PDF flattens every
#     diagram into one directory by basename
#
# Run:  ./scripts/test-docs-diagrams.sh
#       nix run .#test-docs-diagrams

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${QGIS_DESKTOP_PROJECT_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
DOCS_DIR="$PROJECT_ROOT/docs"

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  printf '  \033[32m✓\033[0m %s\n' "$1"
}

no() {
  FAIL=$((FAIL + 1))
  printf '  \033[31m✗\033[0m %s\n' "$1"
  [ -n "${2:-}" ] && printf '      %s\n' "$2"
}

echo "docs diagrams"

if ! command -v d2 >/dev/null 2>&1; then
  echo "  — skipped: d2 not on PATH (run via 'nix run .#test-docs-diagrams')"
  exit 0
fi

# --- Sources render, and match what is committed ----------------------------
if CHECK_OUTPUT="$(bash "$PROJECT_ROOT/scripts/render-diagrams.sh" --check 2>&1)"; then
  ok "every committed SVG matches its .d2 source"
else
  no "every committed SVG matches its .d2 source" "$CHECK_OUTPUT"
fi

mapfile -t SOURCES < <(find "$DOCS_DIR" -name '*.d2' -not -name '_*' | sort)
if [ "${#SOURCES[@]}" -gt 0 ]; then
  ok "found ${#SOURCES[@]} diagram source(s)"
else
  no "found diagram sources" "no .d2 files under docs/"
fi

# --- Unique basenames -------------------------------------------------------
# The PDF converts every diagram into one working directory and rewrites
# references by basename, so two diagrams called overview.svg in different
# directories would silently print the same picture twice.
DUPES="$(basename -a "${SOURCES[@]}" 2>/dev/null | sort | uniq -d)"
if [ -z "$DUPES" ]; then
  ok "diagram basenames are unique across directories"
else
  no "diagram basenames are unique across directories" "duplicated:$(printf ' %s' "$DUPES")"
fi

# --- Every referenced diagram exists ----------------------------------------
missing=""
while IFS= read -r page; do
  page_dir="$(dirname "$page")"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    [ -f "$page_dir/$ref" ] || missing="$missing
      ${page#"$PROJECT_ROOT/"} -> $ref"
  done < <(grep -oE '\(([^)]*diagrams/[^)]+\.svg)\)' "$page" | tr -d '()')
done < <(find "$DOCS_DIR" -name '*.md')

if [ -z "$missing" ]; then
  ok "every diagram referenced by a page exists"
else
  no "every diagram referenced by a page exists" "missing:$missing"
fi

# --- Rendered output is actually an SVG -------------------------------------
malformed=""
while IFS= read -r svg; do
  head -c 200 "$svg" | grep -q '<svg' || malformed="$malformed ${svg#"$PROJECT_ROOT/"}"
done < <(find "$DOCS_DIR" -path '*/diagrams/*.svg')

if [ -z "$malformed" ]; then
  ok "every rendered diagram is a well-formed SVG"
else
  no "every rendered diagram is a well-formed SVG" "$malformed"
fi

echo ""
echo "─────────────────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
