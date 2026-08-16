<!--
SPDX-FileCopyrightText: Kartoza
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Single sign-on with persistent homes

Identity in Keycloak, state in object storage, nothing durable in the container
between them.

```bash
nix run .#build-docker             # once
echo '127.0.0.1 keycloak' | sudo tee -a /etc/hosts   # once
nix run .#run-sso-homes-scenario   # or: docker compose up
```

Open <http://keycloak:8443>.

| Who | Credentials | Outcome |
|-----|-------------|---------|
| alice | `alice` / `hunter2` | Has the `qgis-user` role — signed in, home restored |
| mallory | `mallory` / `hunter2` | Authenticates, no role — refused by the proxy |
| Keycloak admin | `admin` / `admin` | <http://keycloak:8080/admin> |
| MinIO | `minioadmin` / `minioadmin123` | <http://localhost:9001> |

## Why the hosts entry

The `iss` claim in the token is the issuer URL as Keycloak knows itself, and the
proxy rejects a token whose issuer is not the one it was configured with. The
browser and the container therefore have to reach Keycloak under the same name:
inside the compose network `keycloak` is the container, and the hosts entry
makes it `127.0.0.1` for your browser, where both published ports live.

## What to try

```bash
# the desktop is unreachable without a session
curl -sI http://keycloak:8443/            # 302 to Keycloak

# the proxy is the only public listener
docker exec sso-homes-desktop sh -c 'cat /proc/net/tcp' | head   # 6901 on 127.0.0.1

# the credentials are not in the session
docker exec -u 1000 sso-homes-desktop env | grep -E 'SECRET|ACCESS_KEY'   # nothing
```

Sign in as alice, make a file, wait for `[persist] Saved` in the logs, then
`docker kill sso-homes-desktop && docker compose up -d`. Sign in again: it is
still there.

## Notes

- The realm is shared with `../keycloak-oidc/`, mounted read-only from there,
  so the two examples cannot drift apart.
- All credentials here are public in this repository. Real deployments use the
  `_FILE` variables with mounted secrets, and credentials scoped to the user's
  own bucket prefix.
- One container, one user, one prefix. For a team, run one per person — see the
  scenario page for how that scales.

Full write-up: [docs/scenarios/sso-persistent-homes.md](../../docs/scenarios/sso-persistent-homes.md)

---

Made with love by [Kartoza](https://kartoza.com) ·
[Donate!](https://github.com/sponsors/kartoza) ·
[GitHub](https://github.com/kartoza/qgis-desktop-docker)
