#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kartoza
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Guard: every shipped example keeps the QGIS desktop service under least
# privilege. A new example that copies an old one, or a well-meaning edit that
# "simplifies" the capability block, must not quietly drop the hardening and
# hand a desktop user a wider blast radius than the audit in SECURITY.md
# assumes.
#
# For every docker-compose.yml that runs this image, the desktop service must:
#   * drop ALL capabilities,
#   * add back exactly the agreed allowlist (no more, no less),
#   * set no-new-privileges.
#
# The check is textual on purpose — it needs neither Docker nor a running
# daemon, so it runs in the same sandbox as the other unit tests.
#
# Run:  ./scripts/test-example-hardening.sh
#       nix run .#test-example-hardening

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${QGIS_DESKTOP_PROJECT_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"

# The agreed allowlist. Keep this in step with SECURITY.md and the compose
# files; the test exists precisely so the three cannot drift apart.
EXPECTED_CAPS="AUDIT_WRITE CHOWN DAC_OVERRIDE FOWNER FSETID KILL NET_ADMIN SETGID SETPCAP SETUID"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

# Every compose file that references this image is in scope. Match the image
# name rather than a hand-maintained list, so a new example is covered the
# moment it is added.
mapfile -t COMPOSE_FILES < <(
  grep -rlE 'image:\s*(kartoza:qgis-desktop|ghcr\.io/kartoza/qgis-desktop-docker)' \
    "$PROJECT_ROOT/docker-compose.yml" "$PROJECT_ROOT/examples" \
    --include='docker-compose.yml' 2>/dev/null | sort -u
)

if [ "${#COMPOSE_FILES[@]}" -eq 0 ]; then
  no "found at least one example compose file" "grep matched nothing under $PROJECT_ROOT"
  echo ""
  printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

ok "found ${#COMPOSE_FILES[@]} example compose file(s) that run this image"

# Pull out one service block at a time. `docker compose config` would be the
# authoritative parser, but it needs a daemon and, for some examples, secrets on
# disk — so walk the YAML directly. Each service is a key indented four spaces;
# its body runs until the next such key or end of file.
for f in "${COMPOSE_FILES[@]}"; do
  rel="${f#"$PROJECT_ROOT"/}"

  # Consider only services whose image is this one. awk emits the body of every
  # 4-space-indented service block that contains the image reference.
  # shellcheck disable=SC2016  # $0/fields are awk's, not the shell's
  desktop_bodies="$(awk '
    /^  [a-zA-Z0-9._-]+:[[:space:]]*$/ {
      if (inblk && want) print buf "\036"
      inblk = 1; want = 0; buf = ""; next
    }
    inblk {
      buf = buf $0 "\n"
      if ($0 ~ /image:[[:space:]]*(kartoza:qgis-desktop|ghcr\.io\/kartoza\/qgis-desktop-docker)/) want = 1
    }
    END { if (inblk && want) print buf "\036" }
  ' "$f")"

  # Split on the record separator and check each desktop service body.
  while IFS= read -r -d $'\036' body; do
    [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ] && continue

    # cap_drop must contain ALL.
    if printf '%s' "$body" | grep -Eq '^[[:space:]]*cap_drop:' &&
       printf '%s' "$body" | grep -Eq '^[[:space:]]*-[[:space:]]*ALL[[:space:]]*$'; then
      ok "$rel: drops ALL capabilities"
    else
      no "$rel: drops ALL capabilities" "cap_drop: [ALL] missing"
    fi

    # no-new-privileges must be set.
    if printf '%s' "$body" | grep -Eq 'no-new-privileges:[[:space:]]*true'; then
      ok "$rel: sets no-new-privileges"
    else
      no "$rel: sets no-new-privileges" "security_opt no-new-privileges:true missing"
    fi

    # The added-back caps must equal the allowlist exactly. Collect the cap_add
    # items — every list item that names a bare capability (all-caps token) —
    # and compare as sorted newline lists, so spacing never matters.
    got="$(printf '%s' "$body" \
      | sed -n '/^[[:space:]]*cap_add:/,/^[[:space:]]*[a-zA-Z_]*:/p' \
      | grep -oE '^[[:space:]]*-[[:space:]]*[A-Z_]+' \
      | grep -oE '[A-Z_]+$' \
      | grep -v '^ALL$' \
      | sort -u)"
    want="$(printf '%s' "$EXPECTED_CAPS" | tr ' ' '\n' | sort -u)"

    if [ "$got" = "$want" ]; then
      ok "$rel: adds back exactly the agreed capability allowlist"
    else
      got_line="$(printf '%s' "$got" | tr '\n' ' ')"
      want_line="$(printf '%s' "$want" | tr '\n' ' ')"
      no "$rel: adds back exactly the agreed capability allowlist" "got:  ${got_line}"$'\n'"      want: ${want_line}"
    fi
  done <<< "$desktop_bodies"
done

# SECURITY.md must exist and name each capability, so the compose comments'
# promise of "see SECURITY.md" is real and the rationale cannot silently vanish.
SEC="$PROJECT_ROOT/SECURITY.md"
if [ -r "$SEC" ]; then
  missing=""
  read -ra _expected_caps <<< "$EXPECTED_CAPS"
  for cap in "${_expected_caps[@]}"; do
    grep -q -- "$cap" "$SEC" || missing="$missing $cap"
  done
  if [ -z "$missing" ]; then
    ok "SECURITY.md documents every capability in the allowlist"
  else
    no "SECURITY.md documents every capability in the allowlist" "undocumented:$missing"
  fi
else
  no "SECURITY.md exists" "$SEC not found"
fi

echo ""
echo "─────────────────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
