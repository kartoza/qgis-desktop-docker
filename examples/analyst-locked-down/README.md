<!--
SPDX-FileCopyrightText: Kartoza
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Analyst locked-down session

One analyst, one database, nothing else. Copy/paste blocked in both directions,
the screen watermarked, no terminal, and an egress filter that lets the desktop
reach a co-located PostGIS container and nothing further.

```bash
nix run .#build-docker              # once
nix run .#run-analyst-scenario      # or: docker compose up
```

Open <http://localhost:8443> and sign in as **bob** / **password123**.

| | |
|---|---|
| Desktop | <http://localhost:8443> — `bob` / `password123` |
| Database | `host=db user=bob password=password123 db=gis port=5432` — reachable from the desktop only |

## What it enforces

| Requirement | How |
|-------------|-----|
| Only bob may sign in | `QGIS_DESKTOP_USERS=bob:password123` |
| No copying data out | `KASM_ALLOW_CLIPBOARD_OUT=0`, and the same for paste and the X primary selection |
| Screenshots are attributable | `KASM_WATERMARK_TEXT` with the user and the time |
| No shell | `QGIS_DESKTOP_ALLOW_TERMINAL=0` removes the terminal emulators outright |
| Only the database is reachable | `QGIS_DESKTOP_EGRESS_ALLOW=db`, resolved once at startup |
| The database is not exposed | The `db` service publishes no ports |
| It cannot come up unprotected | The entrypoint fails closed without `NET_ADMIN` |

## Verifying it

The desktop has no terminal, so the checks that need a shell run from the host —
which is exactly the asymmetry the scenario is after:

```bash
docker exec qgis-desktop curl -m5 https://example.com          # times out
docker exec qgis-desktop getent hosts db                       # resolves
docker exec -u 1000 qgis-desktop nft list ruleset              # not permitted
docker exec qgis-desktop nft list table inet qgis_desktop_egress
```

In the desktop itself: the panel has no terminal launcher, the applications
menu has no entry, Ctrl-Alt-T does nothing, and Thunar's *Open Terminal Here*
leads nowhere.

!!! note
    This is an affordance control, not a sandbox. QGIS ships a Python console,
    and anything that can run Python can start a subprocess. What contains a
    determined user is the unprivileged UID, the egress filter and the
    container.

Full write-up, including the UML diagrams and the complete verification
checklist: [docs/scenarios/analyst-locked-down.md](../../docs/scenarios/analyst-locked-down.md)

---

Made with love by [Kartoza](https://kartoza.com) ·
[Donate!](https://github.com/sponsors/kartoza) ·
[GitHub](https://github.com/kartoza/qgis-desktop-docker)
