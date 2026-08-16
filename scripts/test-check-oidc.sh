#!/usr/bin/env bash
# Tests for the OIDC preflight check.
#
# The checker's whole value is telling you WHICH thing is wrong, so the tests
# are about diagnosis rather than exit codes: a check that says "the secret is
# wrong" when the client id is the problem is worse than no check at all.
#
# A fake OIDC provider is served from a directory over a local HTTP server, so
# this needs no network, no Docker and no Keycloak. What it cannot cover is a
# real provider's behaviour — the discovery/introspection contract used here was
# verified against Keycloak 26 by hand, and the cases below pin the parsing.
#
# Run:  ./scripts/test-check-oidc.sh
#       nix run .#test-check-oidc

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${QGIS_DESKTOP_PROJECT_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
CHECKER="$PROJECT_ROOT/scripts/check-oidc-issuer.sh"

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

echo "check-oidc"

for tool in curl jq python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "  — skipped: $tool not on PATH (run via 'nix run .#test-check-oidc')"
    exit 0
  fi
done

# --- A fake provider --------------------------------------------------------
# Behaviour, in one small server:
#   /realms/good/...        a healthy provider
#   /realms/skewed/...      announces a different issuer than the one requested
#   introspect              200 for secret 'right', 401 otherwise
#   auth                    an error page for an unregistered redirect_uri
TMP="$(mktemp -d)"
trap 'kill "${SRV_PID:-}" 2>/dev/null; rm -rf "$TMP"' EXIT

cat > "$TMP/server.py" <<'PY'
import json, re
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

PORT = None  # set from argv

def endpoints(base, realm):
    r = f"{base}/realms/{realm}"
    return {
        "issuer": r,
        "authorization_endpoint": f"{r}/protocol/openid-connect/auth",
        "token_endpoint": f"{r}/protocol/openid-connect/token",
        "introspection_endpoint": f"{r}/protocol/openid-connect/token/introspect",
    }

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        raw = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        u = urlparse(self.path)
        base = f"http://127.0.0.1:{PORT}"
        m = re.match(r"^/realms/([^/]+)/\.well-known/openid-configuration$", u.path)
        if m:
            realm = m.group(1)
            if realm == "missing":
                return self._send(404, '{"error":"Realm does not exist"}')
            if realm == "notjson":
                return self._send(200, "hello", "text/plain")
            # 'skewed' announces itself under a different name than requested
            announced = "other-host" if realm == "skewed" else realm
            return self._send(200, json.dumps(endpoints(base, announced)))

        if "/protocol/openid-connect/auth" in u.path:
            q = parse_qs(u.query)
            cid = (q.get("client_id") or [""])[0]
            redirect = (q.get("redirect_uri") or [""])[0]
            if cid != "qgis-desktop":
                return self._send(400, "We are sorry... Invalid client or Client not found", "text/html")
            if redirect and redirect != "https://desktop.example.com/oauth2/callback":
                return self._send(400, "We are sorry... Invalid parameter: redirect_uri", "text/html")
            return self._send(200, "<html><body>Sign in</body></html>", "text/html")

        return self._send(404, '{"error":"not found"}')

    def do_POST(self):
        u = urlparse(self.path)
        n = int(self.headers.get("Content-Length", 0))
        form = parse_qs(self.rfile.read(n).decode())
        cid = (form.get("client_id") or [""])[0]
        secret = (form.get("client_secret") or [""])[0]

        if u.path.endswith("/token/introspect"):
            if cid == "qgis-desktop" and secret == "right":
                return self._send(200, '{"active":false}')
            return self._send(401, '{"error":"invalid_request","error_description":"Authentication failed."}')

        if u.path.endswith("/token"):
            # Mirrors Keycloak with service accounts off: same `error` either way.
            if cid == "qgis-desktop" and secret == "right":
                return self._send(401, '{"error":"unauthorized_client","error_description":"Client not enabled to retrieve service account"}')
            return self._send(401, '{"error":"unauthorized_client","error_description":"Invalid client or Invalid client credentials"}')

        return self._send(404, '{"error":"not found"}')

if __name__ == "__main__":
    import sys
    PORT = int(sys.argv[1])
    HTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY

# An ephemeral port, so parallel runs and a busy machine do not collide.
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 "$TMP/server.py" "$PORT" >/dev/null 2>&1 &
SRV_PID=$!

BASE="http://127.0.0.1:$PORT"
for _ in $(seq 1 50); do
  curl -sf "$BASE/realms/good/.well-known/openid-configuration" >/dev/null 2>&1 && break
  sleep 0.1
done
if ! curl -sf "$BASE/realms/good/.well-known/openid-configuration" >/dev/null 2>&1; then
  no "the fake provider did not start"
  echo ""
  printf '  \033[31m1 failed\033[0m\n'
  exit 1
fi

# run <realm> <client-id> <secret> <redirect> [roles]
run_check() {
  QGIS_DESKTOP_OIDC_ISSUER_URL="$BASE/realms/$1" \
  QGIS_DESKTOP_OIDC_CLIENT_ID="$2" \
  QGIS_DESKTOP_OIDC_CLIENT_SECRET="$3" \
  QGIS_DESKTOP_OIDC_REDIRECT_URL="$4" \
  QGIS_DESKTOP_OIDC_ALLOWED_ROLES="${5:-}" \
  QGIS_DESKTOP_OIDC_PROVIDER="${QGIS_DESKTOP_OIDC_PROVIDER:-keycloak-oidc}" \
    bash "$CHECKER" 2>&1
}

GOOD_REDIRECT="https://desktop.example.com/oauth2/callback"

# --- A healthy provider passes ----------------------------------------------
OUT="$(run_check good qgis-desktop right "$GOOD_REDIRECT" qgis-user)"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  ok "a correctly configured provider exits 0"
else
  no "a correctly configured provider should exit 0" "got $STATUS"
fi
grep -q "issuer matches exactly" <<< "$OUT" \
  && ok "confirms the issuer matches" \
  || no "should confirm the issuer matches"
grep -q "secret is accepted" <<< "$OUT" \
  && ok "accepts a valid client secret" \
  || no "should accept a valid client secret" "$(head -20 <<< "$OUT")"
grep -q "redirect URI is accepted" <<< "$OUT" \
  && ok "accepts a registered redirect URI" \
  || no "should accept a registered redirect URI"

# --- Each failure is named correctly ----------------------------------------
# The point of the whole script: the right diagnosis, not just a non-zero exit.
OUT="$(run_check good qgis-desktop wrong-secret "$GOOD_REDIRECT" qgis-user)"
if grep -q "client secret is wrong" <<< "$OUT"; then
  ok "a wrong secret is reported as a wrong secret"
else
  no "a wrong secret should be named as such" "$(grep -A2 'Client credentials' <<< "$OUT" | head -4)"
fi
grep -q "no client called" <<< "$OUT" \
  && no "a wrong secret must not be blamed on the client id" \
  || ok "a wrong secret is not blamed on the client id"

OUT="$(run_check good no-such-client right "$GOOD_REDIRECT" qgis-user)"
grep -q "no client called 'no-such-client'" <<< "$OUT" \
  && ok "an unknown client id is reported as an unknown client" \
  || no "an unknown client id should be named as such" "$(grep -A2 'Client credentials' <<< "$OUT" | head -4)"

OUT="$(run_check good qgis-desktop right "https://wrong.example.com/oauth2/callback" qgis-user)"
grep -q "rejects this redirect URI" <<< "$OUT" \
  && ok "an unregistered redirect URI is reported" \
  || no "an unregistered redirect URI should be reported"

OUT="$(run_check skewed qgis-desktop right "$GOOD_REDIRECT" qgis-user)"
if grep -q "issuer mismatch" <<< "$OUT"; then
  ok "an issuer that announces a different name is caught"
else
  no "an issuer mismatch should be caught" "$(head -12 <<< "$OUT")"
fi

OUT="$(run_check missing qgis-desktop right "$GOOD_REDIRECT" qgis-user)"
STATUS=$?
grep -q "cannot reach the discovery document" <<< "$OUT" \
  && ok "a missing realm is reported against discovery" \
  || no "a missing realm should be reported against discovery"
grep -q "realm name in the URL is wrong" <<< "$OUT" \
  && ok "a 404 suggests the realm name" \
  || no "a 404 should suggest the realm name"

OUT="$(run_check notjson qgis-desktop right "$GOOD_REDIRECT" qgis-user)"
grep -q "not an OIDC discovery document" <<< "$OUT" \
  && ok "a non-OIDC response is rejected clearly" \
  || no "a non-OIDC response should be rejected clearly"

# --- Warnings, not failures -------------------------------------------------
OUT="$(run_check good qgis-desktop right "$GOOD_REDIRECT" "")"
STATUS=$?
if grep -q "no QGIS_DESKTOP_OIDC_ALLOWED_ROLES" <<< "$OUT" && [ "$STATUS" -eq 0 ]; then
  ok "no role gating warns but does not fail"
else
  no "no role gating should warn without failing" "exit $STATUS"
fi

OUT="$(QGIS_DESKTOP_OIDC_PROVIDER=oidc run_check good qgis-desktop right "$GOOD_REDIRECT" qgis-user)"
grep -q "needs QGIS_DESKTOP_OIDC_PROVIDER=keycloak-oidc" <<< "$OUT" \
  && ok "roles with a non-Keycloak provider is an error" \
  || no "roles with a non-Keycloak provider should be an error"

# --- Missing configuration --------------------------------------------------
OUT="$(QGIS_DESKTOP_OIDC_ISSUER_URL="" QGIS_DESKTOP_OIDC_CLIENT_ID="" \
       QGIS_DESKTOP_OIDC_CLIENT_SECRET="" bash "$CHECKER" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && grep -q "missing required variable" <<< "$OUT"; then
  ok "missing variables exit 2 with a usable message"
else
  no "missing variables should exit 2 with a usable message" "exit $STATUS"
fi

# The secret can come from a file, the way the container reads it.
SECRET_FILE="$TMP/secret"
printf 'right' > "$SECRET_FILE"
OUT="$(QGIS_DESKTOP_OIDC_ISSUER_URL="$BASE/realms/good" \
       QGIS_DESKTOP_OIDC_CLIENT_ID=qgis-desktop \
       QGIS_DESKTOP_OIDC_CLIENT_SECRET="" \
       QGIS_DESKTOP_OIDC_CLIENT_SECRET_FILE="$SECRET_FILE" \
       QGIS_DESKTOP_OIDC_REDIRECT_URL="$GOOD_REDIRECT" \
       QGIS_DESKTOP_OIDC_ALLOWED_ROLES=qgis-user bash "$CHECKER" 2>&1)"
grep -q "secret is accepted" <<< "$OUT" \
  && ok "reads the secret from _CLIENT_SECRET_FILE" \
  || no "should read the secret from _CLIENT_SECRET_FILE"

# --- Plain HTTP -------------------------------------------------------------
OUT="$(run_check good qgis-desktop right "$GOOD_REDIRECT" qgis-user)"
grep -qi "plain HTTP" <<< "$OUT" \
  && ok "a non-HTTPS issuer is called out" \
  || no "a non-HTTPS issuer should be called out"

echo ""
echo "─────────────────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '  \033[31m%d failed\033[0m, %d passed\n' "$FAIL" "$PASS"
  exit 1
fi
printf '  \033[32m%d passed\033[0m, 0 failed\n' "$PASS"
