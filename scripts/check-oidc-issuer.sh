#!/usr/bin/env bash
# Preflight an existing OIDC provider before pointing a container at it.
#
# Every failure this reports is one that otherwise shows up as a redirect loop
# or a bare 403 with nothing useful in the logs. Checking first turns "it does
# not work" into a named cause.
#
# Run:  ./scripts/check-oidc-issuer.sh
#       nix run .#check-oidc
#
# Reads the same variables the container does, so a passing check means the
# environment you just verified is the environment you are about to run:
#
#   QGIS_DESKTOP_OIDC_ISSUER_URL     required
#   QGIS_DESKTOP_OIDC_CLIENT_ID      required
#   QGIS_DESKTOP_OIDC_CLIENT_SECRET  required (or _FILE)
#   QGIS_DESKTOP_OIDC_REDIRECT_URL   optional, strongly recommended
#   QGIS_DESKTOP_OIDC_ALLOWED_ROLES  optional, reported only
#
# Nothing here writes anything, and no browser is involved: it is discovery
# plus one token request. It cannot prove a human can log in — only that the
# pieces the proxy needs are present and agree with each other.

set -uo pipefail

pass=0
fail=0
warn=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }
note() { printf '  \033[33m!\033[0m %s\n' "$1"; warn=$((warn + 1)); }
info() { printf '    %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

ISSUER="${QGIS_DESKTOP_OIDC_ISSUER_URL:-}"
CLIENT_ID="${QGIS_DESKTOP_OIDC_CLIENT_ID:-}"
CLIENT_SECRET="${QGIS_DESKTOP_OIDC_CLIENT_SECRET:-}"
REDIRECT_URL="${QGIS_DESKTOP_OIDC_REDIRECT_URL:-}"
ROLES="${QGIS_DESKTOP_OIDC_ALLOWED_ROLES:-}"

# The container accepts the secret in a file so it never lands in `docker
# inspect`; accept the same here, or checking would mean putting it back in the
# environment just to test it.
if [ -z "${CLIENT_SECRET}" ] && [ -n "${QGIS_DESKTOP_OIDC_CLIENT_SECRET_FILE:-}" ]; then
  if [ -r "${QGIS_DESKTOP_OIDC_CLIENT_SECRET_FILE}" ]; then
    CLIENT_SECRET="$(cat "${QGIS_DESKTOP_OIDC_CLIENT_SECRET_FILE}")"
  else
    echo "ERROR: cannot read QGIS_DESKTOP_OIDC_CLIENT_SECRET_FILE=${QGIS_DESKTOP_OIDC_CLIENT_SECRET_FILE}" >&2
    exit 2
  fi
fi

MISSING=""
[ -n "${ISSUER}" ]        || MISSING="${MISSING} QGIS_DESKTOP_OIDC_ISSUER_URL"
[ -n "${CLIENT_ID}" ]     || MISSING="${MISSING} QGIS_DESKTOP_OIDC_CLIENT_ID"
[ -n "${CLIENT_SECRET}" ] || MISSING="${MISSING} QGIS_DESKTOP_OIDC_CLIENT_SECRET"
if [ -n "${MISSING}" ]; then
  cat >&2 <<EOF
ERROR: missing required variable(s):${MISSING}

Set them the way you will set them on the container, then re-run:

  export QGIS_DESKTOP_OIDC_ISSUER_URL=https://sso.example.com/realms/gis
  export QGIS_DESKTOP_OIDC_CLIENT_ID=qgis-desktop
  export QGIS_DESKTOP_OIDC_CLIENT_SECRET=…
  export QGIS_DESKTOP_OIDC_REDIRECT_URL=https://qgis.example.com/oauth2/callback
EOF
  exit 2
fi

CURL=(curl --silent --show-error --max-time 15)
[ "${QGIS_DESKTOP_OIDC_INSECURE_SKIP_VERIFY:-0}" = "1" ] && CURL+=(--insecure)

printf '\033[1mOIDC preflight\033[0m\n'
info "issuer:   ${ISSUER}"
info "client:   ${CLIENT_ID}"
info "redirect: ${REDIRECT_URL:-(not set — will default to http://localhost:8443/oauth2/callback)}"

# ---------------------------------------------------------------------------
head_ "1. Discovery"
# ---------------------------------------------------------------------------
DISCOVERY_URL="${ISSUER%/}/.well-known/openid-configuration"
DISCOVERY="$("${CURL[@]}" -w '\n%{http_code}' "${DISCOVERY_URL}" 2>&1)"
DISC_STATUS="$(printf '%s' "${DISCOVERY}" | tail -1)"
DISCOVERY="$(printf '%s' "${DISCOVERY}" | sed '$d')"

if [ "${DISC_STATUS}" != "200" ]; then
  bad "cannot reach the discovery document (HTTP ${DISC_STATUS:-none})"
  info "${DISCOVERY_URL}"
  case "${DISC_STATUS}" in
    404) info "404 usually means the realm name in the URL is wrong. A Keycloak"
         info "issuer ends in /realms/<realm>, not /auth or /realms/<realm>/account." ;;
    000|"") info "No response at all: DNS, firewall, or a TLS error. If the certificate"
            info "is self-signed, set QGIS_DESKTOP_OIDC_INSECURE_SKIP_VERIFY=1 for this"
            info "check — and fix the certificate before production." ;;
  esac
  printf '\n\033[31mFAILED\033[0m — nothing else can be checked until discovery works.\n'
  exit 1
fi
ok "discovery document fetched"

json_get() { printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null; }

DISC_ISSUER="$(json_get "${DISCOVERY}" .issuer)"
TOKEN_URL="$(json_get "${DISCOVERY}" .token_endpoint)"
AUTH_URL="$(json_get "${DISCOVERY}" .authorization_endpoint)"
INTROSPECT_URL="$(json_get "${DISCOVERY}" .introspection_endpoint)"

if [ -z "${DISC_ISSUER}" ]; then
  bad "the response is not an OIDC discovery document"
  info "Got something at that URL, but it has no \"issuer\" field."
  printf '\n\033[31mFAILED\033[0m\n'
  exit 1
fi

# The single most common cause of a login loop: the provider announces itself
# under a different name than the one configured, so the token's `iss` does not
# match and the proxy rejects a technically valid login.
if [ "${DISC_ISSUER%/}" = "${ISSUER%/}" ]; then
  ok "issuer matches exactly: ${DISC_ISSUER}"
else
  bad "issuer mismatch — the proxy will reject every token"
  info "you configured:   ${ISSUER}"
  info "the IdP announces: ${DISC_ISSUER}"
  info "Use the IdP's own value verbatim, or fix the IdP's hostname setting."
  info "Both sides must also agree with what the BROWSER uses: a container that"
  info "reaches it as http://keycloak:8080 and a browser that reaches it as"
  info "http://localhost:8080 cannot both be right."
fi

[ -n "${AUTH_URL}" ] && ok "authorization endpoint: ${AUTH_URL}" \
  || bad "no authorization_endpoint in the discovery document"
[ -n "${TOKEN_URL}" ] && ok "token endpoint: ${TOKEN_URL}" \
  || bad "no token_endpoint in the discovery document"

# ---------------------------------------------------------------------------
head_ "2. Client credentials"
# ---------------------------------------------------------------------------
# Token introspection is the clean way to test a client secret without a
# browser: the endpoint authenticates the CLIENT, so a deliberately invalid
# token still proves the credentials. 200 means they were accepted, 401 means
# they were not — regardless of which grants the client has enabled.
#
# The obvious alternative, a client_credentials request, cannot tell you this:
# with service accounts off (the correct setting here) Keycloak answers
# `unauthorized_client` for a GOOD secret and `unauthorized_client` for a bad
# one, differing only in a human-readable description.
secret_verdict=""
if [ -n "${INTROSPECT_URL}" ]; then
  INTRO_STATUS="$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X POST "${INTROSPECT_URL}" \
    -d 'token=not-a-real-token' \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "client_secret=${CLIENT_SECRET}" 2>&1)"
  case "${INTRO_STATUS}" in
    200) secret_verdict=good ;;
    401|403) secret_verdict=bad ;;
    *)   secret_verdict=unknown ;;
  esac
elif [ -n "${TOKEN_URL}" ]; then
  # No introspection endpoint advertised. Fall back to client_credentials and
  # read the description, which is provider-specific and less reliable.
  TOKEN_RESP="$("${CURL[@]}" -w '\n%{http_code}' -X POST "${TOKEN_URL}" \
    -d grant_type=client_credentials \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "client_secret=${CLIENT_SECRET}" 2>&1)"
  TOKEN_STATUS="$(printf '%s' "${TOKEN_RESP}" | tail -1)"
  TOKEN_BODY="$(printf '%s' "${TOKEN_RESP}" | sed '$d')"
  TOKEN_DESC="$(json_get "${TOKEN_BODY}" .error_description)"
  if [ "${TOKEN_STATUS}" = "200" ]; then
    secret_verdict=good
  elif printf '%s' "${TOKEN_DESC}" | grep -qi 'service account'; then
    secret_verdict=good      # rejected for the grant, not for the credentials
  elif printf '%s' "${TOKEN_DESC}" | grep -qi 'invalid client'; then
    secret_verdict=bad
  else
    secret_verdict=unknown
  fi
fi

case "${secret_verdict}" in
  good)
    ok "client '${CLIENT_ID}' exists and the secret is accepted"
    ;;
  bad)
    # Distinguish an unknown client from a wrong secret: the authorization
    # endpoint complains about the client id specifically.
    PROBE_BODY="$("${CURL[@]}" -G "${AUTH_URL}" \
      --data-urlencode "client_id=${CLIENT_ID}" \
      --data-urlencode "response_type=code" \
      --data-urlencode "scope=openid" 2>&1)"
    if printf '%s' "${PROBE_BODY}" | grep -qi 'client.*not found\|invalid.*client\|unknown.*client'; then
      bad "no client called '${CLIENT_ID}' in this realm"
      info "Check the realm in the issuer URL is the one holding the client."
    else
      bad "the client secret is wrong"
      info "Keycloak: Clients → ${CLIENT_ID} → Credentials → Client secret."
      info "If there is no Credentials tab, the client is public — set"
      info "'Client authentication: On' to make it confidential. A public"
      info "client has no secret and cannot be used here."
    fi
    ;;
  unknown)
    note "could not verify the client secret"
    info "The provider did not answer in a way this check understands. The"
    info "container will tell you at startup if the secret is wrong."
    ;;
esac

# ---------------------------------------------------------------------------
head_ "3. Redirect URI"
# ---------------------------------------------------------------------------
# Ask the authorization endpoint what it thinks of this redirect_uri. Keycloak
# answers "Invalid parameter: redirect_uri" on its own error page rather than
# redirecting, so an unregistered URI is detectable without a browser.
if [ -z "${REDIRECT_URL}" ]; then
  note "QGIS_DESKTOP_OIDC_REDIRECT_URL is not set"
  info "It defaults to http://localhost:8443/oauth2/callback, which is fine for"
  info "a laptop and wrong for anything with a real hostname. Whatever you use"
  info "must be registered on the client as a valid redirect URI."
elif [ -n "${AUTH_URL}" ]; then
  PROBE="$("${CURL[@]}" -o /dev/null -w '%{http_code}' -G "${AUTH_URL}" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "redirect_uri=${REDIRECT_URL}" \
    --data-urlencode "response_type=code" \
    --data-urlencode "scope=openid" 2>&1)"
  BODY="$("${CURL[@]}" -G "${AUTH_URL}" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "redirect_uri=${REDIRECT_URL}" \
    --data-urlencode "response_type=code" \
    --data-urlencode "scope=openid" 2>&1)"

  if printf '%s' "${BODY}" | grep -qi 'invalid.*redirect_uri\|redirect_uri.*invalid'; then
    bad "the IdP rejects this redirect URI"
    info "${REDIRECT_URL}"
    info "Keycloak: Clients → ${CLIENT_ID} → Settings → Valid redirect URIs."
    info "It must match exactly, including scheme, port and the /oauth2/callback"
    info "path. Wildcards are allowed but a trailing /* does not cover a"
    info "different host or scheme."
  elif printf '%s' "${BODY}" | grep -qi 'invalid.*client\|client.*not found'; then
    bad "the IdP does not recognise client '${CLIENT_ID}' at the authorization endpoint"
  elif [ "${PROBE}" = "200" ] || [ "${PROBE}" = "302" ]; then
    ok "redirect URI is accepted: ${REDIRECT_URL}"
    info "(the IdP served a login page rather than an error)"
  else
    note "could not confirm the redirect URI (HTTP ${PROBE})"
  fi
fi

# ---------------------------------------------------------------------------
head_ "4. Authorisation"
# ---------------------------------------------------------------------------
# Role gating cannot be verified without a user, but the wiring around it can:
# roles only reach the proxy from a keycloak-oidc provider.
PROVIDER="${QGIS_DESKTOP_OIDC_PROVIDER:-keycloak-oidc}"
if [ -n "${ROLES}" ]; then
  if [ "${PROVIDER}" = "keycloak-oidc" ]; then
    ok "role gating on: ${ROLES}"
    info "Every user who should get a desktop needs this realm role — check one"
    info "in Users → <name> → Role mapping before you blame the container."
  else
    bad "QGIS_DESKTOP_OIDC_ALLOWED_ROLES needs QGIS_DESKTOP_OIDC_PROVIDER=keycloak-oidc"
    info "got: ${PROVIDER}"
  fi
else
  note "no QGIS_DESKTOP_OIDC_ALLOWED_ROLES set"
  info "ANY user your IdP can authenticate will get a desktop. That is a"
  info "deliberate choice on an internal realm, and a mistake on a shared one."
fi

case "${ISSUER}" in
  https://*) ok "issuer is HTTPS" ;;
  http://localhost*|http://127.0.0.1*|http://keycloak*) note "issuer is plain HTTP (fine for a local demo, not for production)" ;;
  http://*) bad "issuer is plain HTTP — tokens and the client secret cross the network in clear text" ;;
esac

# ---------------------------------------------------------------------------
printf '\n─────────────────────────────────────────\n'
if [ "${fail}" -gt 0 ]; then
  printf '  \033[31m%d problem(s)\033[0m, %d warning(s), %d check(s) passed\n' "${fail}" "${warn}" "${pass}"
  printf '  Fix the ✗ lines above before starting the container.\n'
  exit 1
fi
printf '  \033[32mReady\033[0m — %d check(s) passed, %d warning(s)\n' "${pass}" "${warn}"
printf '  Start it with:  nix run .#run-oidc\n'
exit 0
