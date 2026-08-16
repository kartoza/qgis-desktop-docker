<!--
SPDX-FileCopyrightText: Kartoza
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Federating the customer's identity provider

Keycloak in front of somebody else's directory — the shape nearly every real
deployment ends up with, because the customer already has Entra ID, Google
Workspace, Okta or LDAP and is not moving off it.

```bash
nix run .#build-docker                  # once
echo '127.0.0.1 keycloak' | sudo tee -a /etc/hosts   # once, for the browser
nix run .#run-federated-idp-scenario    # or: docker compose up
```

Open <http://keycloak:8443>. There is no password box — only a **Corporate
sign-in** button, because the realm has no users of its own.

| Who | Credentials | Upstream group | Outcome |
|-----|-------------|----------------|---------|
| Bob | `bob` / `hunter2` | `/gis-team` | Mapper grants `qgis-user` → desktop |
| Carol | `carol` / `hunter2` | `/finance` | Authenticates, no role → **403** |
| admin | `admin` / `admin` | — | <http://keycloak:8080/admin> |

Carol is the point: correct password, good standing, still refused.
Authentication and entitlement are different questions.

## Two realms stand in for two systems

- **`corporate`** — the customer's directory. In production this is Entra ID or
  Okta and you do not control it.
- **`qgis`** — yours. It holds no users. It brokers `corporate`, and an
  `oidc-role-idp-mapper` turns membership of `/gis-team` into the `qgis-user`
  role the container gates on.

The container only ever talks to your realm. Swapping the upstream provider,
adding a second one, or bolting on MFA changes the broker only.

`syncMode: FORCE` on the mapper matters more than it looks: on `IMPORT` the role
is granted once and never re-evaluated, so someone removed from `/gis-team`
keeps access forever.

## Pointing it at a real provider

Replace the `corporate` realm with the customer's issuer. What changes is only
where the group claim comes from — Entra ID emits group **object IDs**, Google
emits no groups at all by default, Okta needs a claim added to the authorization
server. See the docs page for the per-provider table.

Full write-up: [`docs/scenarios/federated-idp.md`](../../docs/scenarios/federated-idp.md)
