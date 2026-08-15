<!--
SPDX-FileCopyrightText: Kartoza
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Home persistence

A desktop whose home directory lives in object storage: restored before the
session starts, saved every 60 seconds and again on shutdown. MinIO stands in
for DigitalOcean, Hetzner or AWS — the container cannot tell the difference.

```bash
nix run .#build-docker            # once
nix run .#run-persistence-demo    # or: docker compose up
```

| | |
|---|---|
| Desktop | <http://localhost:8443> — `user` / `password` |
| MinIO console | <http://localhost:9001> — `minioadmin` / `minioadmin123` |

## What to try

**Survive a hard kill.** Make a file on the desktop, wait for `[persist] Saved`
in the logs, then:

```bash
docker kill qgis-desktop-persist
docker compose up -d
```

It comes back. A `docker kill` is a `SIGKILL` with no warning, so you lose at
most one interval; `docker compose stop` sends `SIGTERM` first and the final
save costs you nothing.

**Hand the user a file.** In the MinIO console, upload something into
`qgis-homes/tim-4f2f96a9/inbox/`. Within a minute it is on the desktop and the
inbox is empty again. Put it in `provision/` instead and it arrives at *every*
container start and stays in the bucket — that is where templates and base
layers go.

**Watch the mirror bite.** Upload a file into `.../home/` directly. The next
save deletes it, because `home/` is a mirror of the container and a file that
is not in the container is one the user deleted. It is not destroyed: look in
`.persist-trash/<timestamp>/`.

**See what it thinks.**

```bash
docker exec qgis-desktop-persist qgis-desktop-persist status
```

**Prove the credentials are out of reach.** The desktop user has a Python
console in QGIS, so assume they can run anything as uid 1000:

```bash
docker exec -u 1000 qgis-desktop-persist cat /run/qgis-desktop/persist/rclone.conf
docker exec -u 1000 qgis-desktop-persist env | grep SECRET
```

Permission denied, and nothing.

## Notes

- The MinIO credentials are in the compose file and therefore in the
  container's environment, where `docker inspect` can read them. That is fine
  for a demo; use `QGIS_DESKTOP_PERSIST_ACCESS_KEY_FILE` and a mounted secret
  for anything real.
- `stop_grace_period: 60s` gives the final save room before Docker escalates to
  `SIGKILL`. Kubernetes calls the same thing `terminationGracePeriodSeconds`.
- The bucket is a named volume, so it survives `docker compose down` — but not
  `down -v`, which throws the home directory away with it.
- The quota is enforced client-side: over 2G, saving stops and a
  `PERSISTENCE-WARNING.txt` appears in the home directory. `df` inside the
  desktop still reports the container filesystem, because that is what the home
  directory actually is.

Full write-up: [docs/configuration/persistence.md](../../docs/configuration/persistence.md)

---

Made with love by [Kartoza](https://kartoza.com) ·
[Donate!](https://github.com/sponsors/kartoza) ·
[GitHub](https://github.com/kartoza/qgis-desktop-docker)
