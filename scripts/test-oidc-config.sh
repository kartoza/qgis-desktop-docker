#!/usr/bin/env bash
# Unit tests for the QGIS_DESKTOP_AUTH_MODE=oidc plumbing.
#
# Covers config/oidc/oidc-config.sh (validation + secret materialisation) and
# config/oidc/oidc-proxy.sh (the flag list handed to oauth2-proxy). Neither
# needs Docker, a container, or an identity provider: the proxy is replaced by
# a stub that prints the arguments it was called with.
#
# Run:  ./scripts/test-oidc-config.sh
#       nix run .#test-oidc

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# QGIS_DESKTOP_PROJECT_ROOT lets `nix run .#test-oidc` point the tests at the flake
# source in the store, where this script has no checkout above it.
PROJECT_ROOT="${QGIS_DESKTOP_PROJECT_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
OIDC_CONFIG="$PROJECT_ROOT/config/oidc/oidc-config.sh"
OIDC_PROXY="$PROJECT_ROOT/config/oidc/oidc-proxy.sh"

WORK="$(mktemp -d -t qgis-desktop-oidc-tests.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Resolve the real oauth2-proxy BEFORE the stub goes on PATH. When it is
# available (it is under `nix run .#test-oidc`, and in CI) every flag we emit is
# checked against its own --help, which is the only way to catch a flag that was
# renamed or never existed. Without it those tests are skipped.
REAL_OAUTH2_PROXY="$(command -v oauth2-proxy 2>/dev/null || true)"

# A stub oauth2-proxy that records its arguments instead of running anything.
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/oauth2-proxy" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@"
STUB
chmod +x "$STUB_BIN/oauth2-proxy"

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

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) ok "$label" ;;
    *) no "$label" "expected to find: $needle" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) no "$label" "did not expect: $needle" ;;
    *) ok "$label" ;;
  esac
}

# $STATUS is set by run_config / run_proxy below.
assert_ok() {
  if [ "$STATUS" -eq 0 ]; then ok "$1"; else no "$1" "exited $STATUS: $OUTPUT"; fi
}

assert_fails() {
  if [ "$STATUS" -ne 0 ]; then ok "$1"; else no "$1" "expected a non-zero exit"; fi
}

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" = "$expected" ]; then
    ok "$label"
  else
    no "$label" "expected '$expected', got '$actual'"
  fi
}

# Run oidc-config.sh in a clean environment with only the QGIS_DESKTOP_OIDC_* vars the
# caller passed as NAME=VALUE arguments. Its stdout+stderr go to $OUTPUT and
# its exit status to $STATUS.
run_config() {
  local runtime_dir="$WORK/run-$RANDOM"
  OUTPUT="$(
    env -i \
      PATH="$PATH" \
      HOME="$WORK" \
      QGIS_DESKTOP_OIDC_RUNTIME_DIR="$runtime_dir" \
      QGIS_DESKTOP_OIDC_PROXY_UID="$(id -u)" \
      QGIS_DESKTOP_OIDC_PROXY_GID="$(id -g)" \
      "$@" \
      bash "$OIDC_CONFIG" 2>&1
  )"
  STATUS=$?
  SECRETS_FILE="$runtime_dir/secrets.cfg"
}

# Same for oidc-proxy.sh, with the stub oauth2-proxy on PATH.
run_proxy() {
  local runtime_dir="$WORK/proxyrun"
  mkdir -p "$runtime_dir"
  printf 'client_secret = "s"\ncookie_secret = "c"\n' > "$runtime_dir/secrets.cfg"
  OUTPUT="$(
    env -i \
      PATH="$STUB_BIN:$PATH" \
      HOME="$WORK" \
      QGIS_DESKTOP_OIDC_RUNTIME_DIR="$runtime_dir" \
      "$@" \
      bash "$OIDC_PROXY" 2>&1
  )"
  STATUS=$?
}

echo "qgis-desktop-oidc-config"

# --- Required configuration -------------------------------------------------
run_config QGIS_DESKTOP_OIDC_CLIENT_ID=c QGIS_DESKTOP_OIDC_CLIENT_SECRET=s \
  QGIS_DESKTOP_OIDC_REDIRECT_URL=http://localhost:8443/oauth2/callback
assert_fails "missing issuer url is fatal"
assert_contains "$OUTPUT" "QGIS_DESKTOP_OIDC_ISSUER_URL" "missing issuer url names the variable"

run_config QGIS_DESKTOP_OIDC_ISSUER_URL=https://idp/realms/r QGIS_DESKTOP_OIDC_CLIENT_ID=c \
  QGIS_DESKTOP_OIDC_REDIRECT_URL=http://localhost:8443/oauth2/callback
assert_fails "missing client secret is fatal"

run_config QGIS_DESKTOP_OIDC_ISSUER_URL=ftp://idp/realms/r QGIS_DESKTOP_OIDC_CLIENT_ID=c \
  QGIS_DESKTOP_OIDC_CLIENT_SECRET=s QGIS_DESKTOP_OIDC_REDIRECT_URL=http://localhost:8443/oauth2/callback
assert_fails "non-http issuer scheme is fatal"

# --- Happy path -------------------------------------------------------------
run_config QGIS_DESKTOP_OIDC_ISSUER_URL=https://idp.example.com/realms/qgis \
  QGIS_DESKTOP_OIDC_CLIENT_ID=qgis-desktop QGIS_DESKTOP_OIDC_CLIENT_SECRET=super-secret \
  QGIS_DESKTOP_OIDC_REDIRECT_URL=https://gis.example.com/oauth2/callback
assert_ok "valid configuration succeeds"
if [ -f "$SECRETS_FILE" ]; then ok "secrets file written"; else no "secrets file written"; fi
MODE="$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || echo "?")"
assert_equals "$MODE" "400" "secrets file is 0400"
assert_contains "$(cat "$SECRETS_FILE")" 'client_secret = "super-secret"' "client secret written"
assert_contains "$(cat "$SECRETS_FILE")" 'cookie_secret = ' "cookie secret written"
assert_not_contains "$OUTPUT" "super-secret" "secret is not echoed to the log"
assert_contains "$OUTPUT" "generated" "generated cookie secret is called out"

# A generated cookie secret must decode to 32 bytes: 43 base64url characters.
COOKIE_LEN="$(sed -n 's/^cookie_secret = "\(.*\)"$/\1/p' "$SECRETS_FILE" | tr -d '\n' | wc -c)"
assert_equals "$COOKIE_LEN" "43" "generated cookie secret is 32 bytes of base64url"

# --- Secrets from files -----------------------------------------------------
printf 'from-a-file\n' > "$WORK/client-secret"
run_config QGIS_DESKTOP_OIDC_ISSUER_URL=https://idp.example.com/realms/qgis \
  QGIS_DESKTOP_OIDC_CLIENT_ID=c QGIS_DESKTOP_OIDC_CLIENT_SECRET_FILE="$WORK/client-secret" \
  QGIS_DESKTOP_OIDC_REDIRECT_URL=https://gis.example.com/oauth2/callback
assert_ok "client secret can come from a file"
assert_contains "$(cat "$SECRETS_FILE")" 'client_secret = "from-a-file"' \
  "trailing newline stripped from secret file"

run_config QGIS_DESKTOP_OIDC_ISSUER_URL=https://idp.example.com/realms/qgis \
  QGIS_DESKTOP_OIDC_CLIENT_ID=c QGIS_DESKTOP_OIDC_CLIENT_SECRET_FILE="$WORK/nope" \
  QGIS_DESKTOP_OIDC_REDIRECT_URL=https://gis.example.com/oauth2/callback
assert_fails "unreadable secret file is fatal"

# --- TOML escaping ----------------------------------------------------------
run_config QGIS_DESKTOP_OIDC_ISSUER_URL=https://idp.example.com/realms/qgis \
  QGIS_DESKTOP_OIDC_CLIENT_ID=c 'QGIS_DESKTOP_OIDC_CLIENT_SECRET=quo"te\back' \
  QGIS_DESKTOP_OIDC_REDIRECT_URL=https://gis.example.com/oauth2/callback
assert_contains "$(cat "$SECRETS_FILE")" 'client_secret = "quo\"te\\back"' \
  "quotes and backslashes are TOML-escaped"

# --- Supplied cookie secret -------------------------------------------------
run_config QGIS_DESKTOP_OIDC_ISSUER_URL=https://idp.example.com/realms/qgis \
  QGIS_DESKTOP_OIDC_CLIENT_ID=c QGIS_DESKTOP_OIDC_CLIENT_SECRET=s \
  QGIS_DESKTOP_OIDC_COOKIE_SECRET=0123456789abcdef0123456789abcdef \
  QGIS_DESKTOP_OIDC_REDIRECT_URL=https://gis.example.com/oauth2/callback
assert_contains "$(cat "$SECRETS_FILE")" \
  'cookie_secret = "0123456789abcdef0123456789abcdef"' "supplied cookie secret is used"
assert_contains "$OUTPUT" "cookie secret: supplied" "supplied cookie secret is reported"

echo ""
echo "qgis-desktop-oidc-proxy"

BASE_ENV=(
  QGIS_DESKTOP_OIDC_ISSUER_URL=https://idp.example.com/realms/qgis
  QGIS_DESKTOP_OIDC_CLIENT_ID=qgis-desktop
)

# --- Listener and upstream --------------------------------------------------
run_proxy "${BASE_ENV[@]}" \
  QGIS_DESKTOP_OIDC_REDIRECT_URL=http://localhost:8443/oauth2/callback
assert_ok "proxy builds its argument list"
assert_contains "$OUTPUT" "--http-address=0.0.0.0:8443" "listens on the public port"
assert_contains "$OUTPUT" "--upstream=http://127.0.0.1:6901/" "proxies to the loopback desktop"
assert_contains "$OUTPUT" "--proxy-websockets=true" "websockets are proxied"
assert_contains "$OUTPUT" "--provider=keycloak-oidc" "defaults to the keycloak provider"
assert_contains "$OUTPUT" "--oidc-issuer-url=https://idp.example.com/realms/qgis" "issuer is passed through"
assert_contains "$OUTPUT" "--email-domain=*" "any email domain by default"
assert_contains "$OUTPUT" "--pass-authorization-header=false" "no token is forwarded upstream"

# --- Cookie security follows the browser-facing scheme ----------------------
assert_contains "$OUTPUT" "--cookie-secure=false" "plain-http deployment gets non-Secure cookies"
assert_contains "$OUTPUT" "WARN" "plain-http deployment is warned about"

run_proxy "${BASE_ENV[@]}" \
  QGIS_DESKTOP_OIDC_REDIRECT_URL=https://gis.example.com/oauth2/callback
assert_contains "$OUTPUT" "--cookie-secure=true" "https deployment gets Secure cookies"

run_proxy "${BASE_ENV[@]}" \
  QGIS_DESKTOP_OIDC_REDIRECT_URL=http://localhost:8443/oauth2/callback \
  QGIS_DESKTOP_OIDC_COOKIE_SECURE=1
assert_contains "$OUTPUT" "--cookie-secure=true" "cookie security can be forced on"

# --- Port overrides ---------------------------------------------------------
run_proxy "${BASE_ENV[@]}" \
  QGIS_DESKTOP_OIDC_REDIRECT_URL=https://gis.example.com/oauth2/callback \
  QGIS_DESKTOP_OIDC_LISTEN_PORT=9443 QGIS_DESKTOP_OIDC_UPSTREAM_PORT=7000
assert_contains "$OUTPUT" "--http-address=0.0.0.0:9443" "listen port override honoured"
assert_contains "$OUTPUT" "--upstream=http://127.0.0.1:7000/" "upstream port override honoured"

# --- Authorisation lists ----------------------------------------------------
run_proxy "${BASE_ENV[@]}" \
  QGIS_DESKTOP_OIDC_REDIRECT_URL=https://gis.example.com/oauth2/callback \
  'QGIS_DESKTOP_OIDC_ALLOWED_GROUPS=/gis-users, /GIS Analysts' \
  QGIS_DESKTOP_OIDC_ALLOWED_ROLES=qgis-user \
  QGIS_DESKTOP_OIDC_EMAIL_DOMAINS=example.com,kartoza.com
assert_contains "$OUTPUT" "--allowed-group=/gis-users" "first group allowed"
assert_contains "$OUTPUT" "--allowed-group=/GIS Analysts" "group names keep inner spaces"
assert_contains "$OUTPUT" "--allowed-role=qgis-user" "keycloak role allowed"
assert_contains "$OUTPUT" "--email-domain=example.com" "first email domain allowed"
assert_contains "$OUTPUT" "--email-domain=kartoza.com" "second email domain allowed"
assert_not_contains "$OUTPUT" "--email-domain=*" "wildcard dropped once domains are listed"

# Roles are Keycloak-specific: asking for them on a generic provider is a
# configuration error, not something to silently ignore.
run_proxy "${BASE_ENV[@]}" \
  QGIS_DESKTOP_OIDC_REDIRECT_URL=https://gis.example.com/oauth2/callback \
  QGIS_DESKTOP_OIDC_PROVIDER=oidc QGIS_DESKTOP_OIDC_ALLOWED_ROLES=qgis-user
assert_fails "roles on a non-keycloak provider are rejected"

# --- TLS --------------------------------------------------------------------
: > "$WORK/tls.crt"
: > "$WORK/tls.key"
run_proxy "${BASE_ENV[@]}" \
  QGIS_DESKTOP_OIDC_REDIRECT_URL=https://gis.example.com/oauth2/callback \
  QGIS_DESKTOP_OIDC_TLS_CERT_FILE="$WORK/tls.crt" QGIS_DESKTOP_OIDC_TLS_KEY_FILE="$WORK/tls.key"
assert_contains "$OUTPUT" "--https-address=0.0.0.0:8443" "TLS listener on the public port"
assert_contains "$OUTPUT" "--http-address=127.0.0.1:0" "plain HTTP parked on loopback"

run_proxy "${BASE_ENV[@]}" \
  QGIS_DESKTOP_OIDC_REDIRECT_URL=https://gis.example.com/oauth2/callback \
  QGIS_DESKTOP_OIDC_TLS_CERT_FILE="$WORK/tls.crt"
assert_fails "half-configured TLS is rejected"

# --- Escape hatch -----------------------------------------------------------
run_proxy "${BASE_ENV[@]}" \
  QGIS_DESKTOP_OIDC_REDIRECT_URL=https://gis.example.com/oauth2/callback \
  'QGIS_DESKTOP_OIDC_EXTRA_ARGS=--cookie-domain=gis.example.com --whitelist-domain=example.com'
assert_contains "$OUTPUT" "--cookie-domain=gis.example.com" "extra args are appended"
assert_contains "$OUTPUT" "--whitelist-domain=example.com" "extra args are word-split"

# --- Missing secrets file ---------------------------------------------------
OUTPUT="$(
  env -i PATH="$STUB_BIN:$PATH" HOME="$WORK" \
    QGIS_DESKTOP_OIDC_RUNTIME_DIR="$WORK/does-not-exist" \
    QGIS_DESKTOP_OIDC_ISSUER_URL=https://idp/realms/r QGIS_DESKTOP_OIDC_CLIENT_ID=c \
    QGIS_DESKTOP_OIDC_REDIRECT_URL=https://gis.example.com/oauth2/callback \
    bash "$OIDC_PROXY" 2>&1
)"
STATUS=$?
assert_fails "proxy refuses to start without its secrets file"

echo ""
echo "flags accepted by oauth2-proxy itself"

# Every flag the launcher can emit, checked against the binary's own --help.
# A renamed or invented flag makes oauth2-proxy print its usage and exit — which
# in a running container means the watchdog stops the whole thing, so this is
# worth catching here rather than in production.
if [ -z "$REAL_OAUTH2_PROXY" ]; then
  echo "  — skipped: oauth2-proxy not on PATH (run via 'nix run .#test-oidc')"
else
  KNOWN_FLAGS="$("$REAL_OAUTH2_PROXY" --help 2>&1 | grep -oE '^[[:space:]]+--[a-z0-9-]+' | tr -d ' ')"

  # Exercise every optional branch at once so the emitted list is exhaustive.
  run_proxy "${BASE_ENV[@]}" \
    QGIS_DESKTOP_OIDC_REDIRECT_URL=https://gis.example.com/oauth2/callback \
    QGIS_DESKTOP_OIDC_ALLOWED_GROUPS=/gis-users \
    QGIS_DESKTOP_OIDC_ALLOWED_ROLES=qgis-user \
    QGIS_DESKTOP_OIDC_EMAIL_DOMAINS=example.com \
    QGIS_DESKTOP_OIDC_TLS_CERT_FILE="$WORK/tls.crt" \
    QGIS_DESKTOP_OIDC_TLS_KEY_FILE="$WORK/tls.key"

  UNKNOWN=""
  while IFS= read -r arg; do
    case "$arg" in
      --*) ;;
      *) continue ;;
    esac
    flag="${arg%%=*}"
    printf '%s\n' "$KNOWN_FLAGS" | grep -qx -- "$flag" || UNKNOWN="$UNKNOWN $flag"
  done <<< "$OUTPUT"

  if [ -z "$UNKNOWN" ]; then
    ok "every emitted flag exists in oauth2-proxy $("$REAL_OAUTH2_PROXY" --version 2>&1 | head -1 | awk '{print $2}')"
  else
    no "every emitted flag exists in oauth2-proxy" "unknown:$UNKNOWN"
  fi
fi

echo ""
echo "─────────────────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
