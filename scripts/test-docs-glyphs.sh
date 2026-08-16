#!/usr/bin/env bash
# Guards the PDF build against characters pdflatex cannot set.
#
# `nix run .#docs-pdf` feeds the docs to pdflatex, which accepts only the subset
# of UTF-8 its inputenc knows. One en dash in one table stops the build with
#
#   ! LaTeX Error: Unicode character ≤ (U+2264) not set up for use with LaTeX.
#
# — ten minutes into a CI run that has already built TeX Live. The PDF build
# rewrites known glyphs first, from docs/pdf/glyph-substitutions.tsv; this
# checks the docs against that same file so an unlisted character fails here
# instead, in a second, naming the file and line.
#
# It reads the page list out of flake.nix rather than globbing docs/, because
# only the pages the PDF actually includes can break the PDF.
#
# Run:  ./scripts/test-docs-glyphs.sh
#       nix run .#test-docs-glyphs

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${QGIS_DESKTOP_PROJECT_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
SUBSTITUTIONS="$PROJECT_ROOT/docs/pdf/glyph-substitutions.tsv"
FLAKE="$PROJECT_ROOT/flake.nix"

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

echo "docs glyphs"

if [ ! -f "$SUBSTITUTIONS" ]; then
  no "docs/pdf/glyph-substitutions.tsv exists" "the PDF build reads this file"
  echo "  0 passed, 1 failed"
  exit 1
fi
ok "the substitution table exists"

# Build the same sed arguments the PDF does, from the same table. Rather than
# comparing lists of characters — which means asking grep to split UTF-8, and
# grep's answer depends on the locale and on which grep you have — this applies
# the substitutions and then looks for any non-ASCII *byte* left behind. That is
# precisely the question pdflatex will ask, and bytes are unambiguous.
GLYPH_ARGS=()
while IFS=$'\t' read -r glyph replacement; do
  case "$glyph" in "" | "#"*) continue ;; esac
  GLYPH_ARGS+=(-e "s|$glyph|$replacement|g")
done < "$SUBSTITUTIONS"

if [ "${#GLYPH_ARGS[@]}" -lt 10 ]; then
  no "the substitution table has entries" "found $((${#GLYPH_ARGS[@]} / 2))"
else
  ok "the substitution table lists $((${#GLYPH_ARGS[@]} / 2)) glyphs"
fi

# The pages the PDF is assembled from, straight out of flake.nix — a page added
# to the PDF without being added here would otherwise go unchecked.
# shellcheck disable=SC2016  # $DOCS_DIR is literal text in flake.nix, not ours
mapfile -t PAGES < <(
  sed -n '/PAGES=(/,/^ *)/p' "$FLAKE" |
    grep -oE '\$DOCS_DIR/[A-Za-z0-9._/-]+\.md' |
    sed "s|\\\$DOCS_DIR|$PROJECT_ROOT/docs|"
)

if [ "${#PAGES[@]}" -lt 5 ]; then
  no "the PDF page list could be read from flake.nix" "found ${#PAGES[@]} pages"
else
  ok "read ${#PAGES[@]} PDF pages from flake.nix"
fi

missing_pages=""
for page in "${PAGES[@]}"; do
  [ -f "$page" ] || missing_pages="$missing_pages ${page#"$PROJECT_ROOT/"}"
done
if [ -z "$missing_pages" ]; then
  ok "every page in the PDF list exists"
else
  no "every page in the PDF list exists" "missing:$missing_pages"
fi

# The check itself: substitute, then look for surviving non-ASCII bytes.
offenders=""
for page in "${PAGES[@]}"; do
  [ -f "$page" ] || continue
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    offenders="$offenders
      ${page#"$PROJECT_ROOT/"}:${hit:0:100}"
  done < <(sed "${GLYPH_ARGS[@]}" "$page" | LC_ALL=C grep -nP '[\x80-\xFF]' || true)
done

if [ -z "$offenders" ]; then
  ok "no page survives substitution with a character pdflatex cannot set"
else
  no "no page survives substitution with a character pdflatex cannot set" \
    "add the offending character(s) to docs/pdf/glyph-substitutions.tsv:${offenders}"
fi

# And the reverse: the PDF build has to be reading the table, or this suite is
# guarding a file nobody uses.
if grep -q 'glyph-substitutions.tsv' "$FLAKE"; then
  ok "the PDF build reads the substitution table"
else
  no "the PDF build reads the substitution table" \
    "flake.nix no longer references glyph-substitutions.tsv"
fi

# Replacements must themselves be ASCII, or a substitution just moves the
# problem downstream.
# -s so a glyph with no replacement (delete it) is skipped rather than read as
# its own replacement.
non_ascii_replacements="$(grep -vE '^\s*(#|$)' "$SUBSTITUTIONS" | cut -s -f2 | grep -P '[^\x00-\x7F]' || true)"
if [ -z "$non_ascii_replacements" ]; then
  ok "every replacement is plain ASCII"
else
  no "every replacement is plain ASCII" "$non_ascii_replacements"
fi

echo ""
echo "─────────────────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
