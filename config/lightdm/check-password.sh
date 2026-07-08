#!/usr/bin/env bash
# pam_exec verifier for KASM_AUTH_MODE=greeter.
#
# Called by pam_exec with:
#   - PAM_USER env var set to the target username
#   - The submitted password on stdin (via `expose_authtok`)
#
# Exits 0 on match, non-zero on failure. Bypasses pam_unix entirely, which
# in this container is unusable (delegates to a non-SUID unix_chkpwd and
# fails with PAM_AUTHINFO_UNAVAIL regardless of /etc/shadow permissions).
#
# Passwords in /etc/shadow are stored as sha512crypt ($6$salt$hash) written
# by the entrypoint via `openssl passwd -6`. Re-hash the submitted password
# with the same salt and compare.

set -eu

u="${PAM_USER:-}"
[ -z "$u" ] && exit 1

# Read password from stdin; PAM appends a NUL terminator with expose_authtok.
p="$(tr -d '\0')"
[ -z "$p" ] && exit 1

# Get the stored shadow entry for this user.
line="$(grep -m1 "^${u}:" /etc/shadow 2>/dev/null || true)"
[ -z "$line" ] && exit 1

stored="$(printf '%s' "$line" | cut -d: -f2)"
case "$stored" in
  ""|"!"*|"*"*|"x") exit 1 ;;  # empty / locked / password missing
esac

# stored is "$6$SALT$HASH". Extract SALT ($6$SALT) and re-hash.
salt_prefix="$(printf '%s' "$stored" | awk -F'$' '{printf "$%s$%s", $2, $3}')"
[ -z "$salt_prefix" ] && exit 1

computed="$(openssl passwd -6 -salt "$(printf '%s' "$stored" | cut -d'$' -f3)" "$p" 2>/dev/null || true)"
[ -z "$computed" ] && exit 1

[ "$stored" = "$computed" ] || exit 1
exit 0
