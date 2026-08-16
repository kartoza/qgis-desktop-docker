<!--
SPDX-FileCopyrightText: Kartoza
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Kiosk display

QGIS on a screen someone walks up to. It opens on your project by itself, there
is no terminal, nothing can be copied off it, and it reaches nothing.

```bash
nix run .#build-docker        # once
nix run .#run-kiosk-scenario  # or: docker compose up
```

Open <http://localhost:8443>. There is no login prompt — see the note below.

## Use your own project

Replace the contents of `project/`:

```text
project/
├── display.qgs        # opened automatically; keep the name or change
│                      # QGIS_DESKTOP_AUTOSTART_QGIS_ARGS in the compose file
└── data/…             # GeoPackages, rasters, styles
```

It is mounted read-only at `/home/user/kiosk`, so a visitor cannot modify it and
a restart returns the display to a known state.

If your project's layers are remote, name their hosts in
`QGIS_DESKTOP_EGRESS_ALLOW` — the allowlist is empty here, which means nothing
outbound gets through at all.

## What to check

```bash
# no terminal, in any of the four places one usually hides
docker exec qgis-desktop-kiosk sh -c 'command -v xfce4-terminal || echo "no terminal"'

# nothing outbound
docker exec qgis-desktop-kiosk curl -m5 https://example.com   # times out

# back to a known state
docker compose restart
```

In the desktop itself: QGIS is already open, the panel has no terminal
launcher, Ctrl-Alt-T does nothing, Thunar's *Open Terminal Here* leads nowhere,
and selecting text in QGIS puts nothing on your local clipboard.

## Two things to be clear about

**No authentication.** On a public display, whoever can reach the URL is meant
to see it. That assumption is only safe if the network in front of it makes it
true. Set `QGIS_DESKTOP_AUTH_MODE=basic` (or `oidc`) if it does not.

**Not a sandbox.** QGIS ships a Python console, and anything that can run
Python can start a subprocess. Removing the terminal removes the obvious route,
not the capability. What contains someone determined is the unprivileged UID,
the egress filter and the container itself.

Full write-up: [docs/scenarios/kiosk.md](../../docs/scenarios/kiosk.md)

---

Made with love by [Kartoza](https://kartoza.com) ·
[Donate!](https://github.com/sponsors/kartoza) ·
[GitHub](https://github.com/kartoza/qgis-desktop-docker)
