<!--
SPDX-FileCopyrightText: Kartoza
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Delivering data through the bucket

Getting files to a user by putting them in object storage — no `docker exec`, no
ticket, no restart.

```bash
nix run .#build-docker            # once
nix run .#run-data-drop-scenario  # or: docker compose up
```

Open <http://localhost:8443> (`user` / `password`). QGIS opens on a project that
came from the bucket's baseline. About a minute later a dispatcher drops
`assets.csv` into `deploy/` and it appears on the desktop.

MinIO's console is at <http://localhost:9001> (`minioadmin` / `minioadmin123`).

## Two prefixes, two different jobs

| Prefix | Arrives | On conflict | Afterwards |
|--------|---------|-------------|------------|
| `baseline/` | Every container start | The user's copy wins | Stays in the bucket |
| `deploy/` | Every interval, while running | The delivery wins | Deleted once delivered |

Use `baseline/` for standard issue — a starter project, house styles. Use
`deploy/` for a one-off hand-off. Getting them the wrong way round means either a
file the user can never delete, or a baseline that arrives once and vanishes.

## Delivering to a real user

Any S3 client works; the container is only reading a prefix.

```bash
aws s3 cp --recursive ./kit/ s3://qgis-homes/surveyor-7c1e/baseline/
aws s3 cp ./ward-7-parcels.gpkg s3://qgis-homes/surveyor-7c1e/deploy/
```

Nothing restarts. The next sync picks it up.

## Notes

- Delivered files are owned by the user, not root: the copy drops to uid 1000
  with `setpriv` first.
- Deliveries count against `QGIS_DESKTOP_PERSIST_QUOTA` like anything else.
- The MinIO credentials here are a demo. Use the `_FILE` variables and a mounted
  secret in production.

Full write-up: [`docs/scenarios/team-data-drop.md`](../../docs/scenarios/team-data-drop.md)
