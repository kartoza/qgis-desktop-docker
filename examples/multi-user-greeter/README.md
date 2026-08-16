<!--
SPDX-FileCopyrightText: Kartoza
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Multi-user greeter session

A shared workstation: several people, one browser tab, a login form inside the
desktop rather than the browser's own.

```bash
nix run .#build-docker          # once
nix run .#run-greeter-scenario  # or: docker compose up
```

Open <http://localhost:8443>.

| Who | Password |
|-----|----------|
| alice | `hunter2` |
| bob | `correct-horse-battery-staple` |

## What to try

**Log out and hand it over.** XFCE menu → Log Out returns to the greeter, and
bob can sign in on the same tab. That is the whole point of this mode: with
HTTP Basic Auth the browser caches the credentials for the origin, and there is
no clean way to make it re-prompt.

**Get the password wrong.** LightDM shows an inline error and asks again. No
tab to close, no site data to clear.

**Check the boundary.** Each entry in `QGIS_DESKTOP_USERS` becomes a real Linux
account with its own UID and a `0700` home:

```bash
docker exec qgis-desktop-greeter ls -la /home
docker exec -u alice qgis-desktop-greeter ls /home/bob   # Permission denied
```

That separation is the kernel's, not the desktop's.

## Notes

- The homes live in one named volume mounted at `/home`, so they survive
  `docker compose down` — but not `down -v`.
- Passwords in a compose file are fine for a demo. In production use
  `QGIS_DESKTOP_USERS_FILE` with a mounted `0600` file, or `oidc` mode and let
  the identity provider hold them.
- Everything else works as usual here: clipboard controls, the watermark, the
  egress allowlist. `QGIS_DESKTOP_OIDC_INNER_MODE=greeter` puts this same
  greeter behind single sign-on.

Full write-up: [docs/scenarios/multi-user-greeter.md](../../docs/scenarios/multi-user-greeter.md)

---

Made with love by [Kartoza](https://kartoza.com) ·
[Donate!](https://github.com/sponsors/kartoza) ·
[GitHub](https://github.com/kartoza/qgis-desktop-docker)
