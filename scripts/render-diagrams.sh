#!/usr/bin/env bash
# Render every .d2 diagram source in docs/ to an SVG beside it.
#
# Why build-time SVG rather than the mermaid blocks we started with: mermaid is
# rendered in the browser, so those diagrams exist in the HTML docs and nowhere
# else. The PDF gets a code fence. Rendering to SVG at build time gives the same
# picture in both, and the PDF pipeline already turns SVG into vector PDF.
#
# Sources live next to the pages that use them, in a diagrams/ directory. The
# rendered SVG is committed alongside its source so GitHub shows it without a
# build step; scripts/test-docs-diagrams.sh fails if the two drift apart.
#
# Run:  ./scripts/render-diagrams.sh [--check]
#       nix run .#docs-diagrams
#
#   --check   render to a temporary directory and compare, changing nothing.
#             Exit 1 if any committed SVG is out of date.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${QGIS_DESKTOP_PROJECT_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
DOCS_DIR="${PROJECT_ROOT}/docs"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# Light theme 0 (neutral default) with dark theme 200 (dark mauve) baked into
# the same file: D2 emits both and switches on prefers-color-scheme, which is
# what the Material theme toggle drives.
D2_ARGS=(--theme 0 --dark-theme 200 --pad 24 --layout dagre)

rendered=0
stale=0
failed=0

mapfile -t SOURCES < <(find "${DOCS_DIR}" -name '*.d2' -not -name '_*' | sort)

if [ "${#SOURCES[@]}" -eq 0 ]; then
  echo "No .d2 sources under ${DOCS_DIR}"
  exit 0
fi

WORK="$(mktemp -d -t qgis-docs-diagrams.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

for src in "${SOURCES[@]}"; do
  rel="${src#"${PROJECT_ROOT}/"}"
  out="${src%.d2}.svg"

  if [ "${CHECK_ONLY}" = "1" ]; then
    tmp="${WORK}/$(basename "${out}")"
    if ! d2 "${D2_ARGS[@]}" "${src}" "${tmp}" >/dev/null 2>&1; then
      echo "  FAILED  ${rel}"
      failed=$((failed + 1))
      continue
    fi
    if [ ! -f "${out}" ]; then
      echo "  MISSING ${rel%.d2}.svg"
      stale=$((stale + 1))
    elif ! cmp -s "${tmp}" "${out}"; then
      echo "  STALE   ${rel%.d2}.svg"
      stale=$((stale + 1))
    fi
    continue
  fi

  if d2 "${D2_ARGS[@]}" "${src}" "${out}" >/dev/null 2>&1; then
    printf '  rendered %s\n' "${rel%.d2}.svg"
    rendered=$((rendered + 1))
  else
    echo "  FAILED  ${rel}" >&2
    d2 "${D2_ARGS[@]}" "${src}" "${out}" 2>&1 | tail -5 >&2
    failed=$((failed + 1))
  fi
done

if [ "${CHECK_ONLY}" = "1" ]; then
  if [ "${failed}" -gt 0 ] || [ "${stale}" -gt 0 ]; then
    echo ""
    echo "${stale} diagram(s) out of date, ${failed} failed to render."
    echo "Run: nix run .#docs-diagrams"
    exit 1
  fi
  echo "All ${#SOURCES[@]} diagrams are up to date."
  exit 0
fi

echo ""
echo "${rendered} rendered, ${failed} failed."
[ "${failed}" -eq 0 ]
