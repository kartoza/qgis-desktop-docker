<!--
SPDX-FileCopyrightText: Kartoza
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Using your own Keycloak

Unlike every other example here, this one starts **no** identity provider —
yours already exists and you have admin on it.

```bash
cp .env.example .env
$EDITOR .env

# from Keycloak: Clients -> qgis-desktop -> Credentials -> Client secret
printf '%s' 'your-client-secret' > secrets/oidc-client-secret
head -c 32 /dev/urandom | base64 | tr -d '=\n' | tr -- '+/' '-_' > secrets/oidc-cookie-secret
chmod 400 secrets/*

# check the Keycloak side BEFORE starting anything
set -a && . ./.env && set +a
QGIS_DESKTOP_OIDC_CLIENT_SECRET_FILE=./secrets/oidc-client-secret nix run .#check-oidc

docker compose up
```

## What to create in Keycloak

Six objects. The [full walkthrough](../../docs/scenarios/keycloak-byo.md) has the
admin-console click-path and the `kcadm.sh` equivalent for each.

| # | Object | Notes |
|---|--------|-------|
| 1 | Realm | An existing one is fine |
| 2 | Client `qgis-desktop` | **Confidential** — Client authentication On. Standard flow only |
| 3 | Valid redirect URI | Your desktop URL + `/oauth2/callback`, matched exactly |
| 4 | Client secret | Into `secrets/oidc-client-secret`, not the environment |
| 5 | Realm role `qgis-user` | Without it, anyone Keycloak authenticates gets a desktop |
| 6 | Users | With the role **and** a complete profile — see below |

## Two things that waste an afternoon

**One hostname for both sides.** The browser and this container must reach
Keycloak under the same name. If the container uses `http://keycloak:8080` and
the browser uses `http://localhost:8080`, the token's `iss` will not match and
the login loops forever. `nix run .#check-oidc` reports the mismatch outright.

**First name and last name are not optional.** Keycloak's *Verify Profile*
action fires on an incomplete profile during login, after the password is
accepted — the user lands on a "complete your account" form and the proxy never
receives a code. The user's `requiredActions` list is empty when this happens,
so the console gives no hint. A temporary password does the same thing.

## Verify the refusal, not just the login

A user **with** the role should reach the desktop; a user **without** it should
get a 403 and `[AuthFailure] Invalid authentication via OAuth2: unauthorized` in
the container logs. Testing only with your own admin account proves Keycloak
works, not that the gate does.

Full write-up: [`docs/scenarios/keycloak-byo.md`](../../docs/scenarios/keycloak-byo.md)
