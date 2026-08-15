<!--
SPDX-FileCopyrightText: Kartoza
SPDX-License-Identifier: GPL-2.0-or-later
-->

# The disposable desktop

The scenario you are meant to break. Kill it, recreate it, run two at once, wipe
the home directory, blow the quota — and watch the guards hold.

If you are about to run this image on Kubernetes, run this first.

```bash
nix run .#build-docker              # once
nix run .#run-disposable-scenario   # or: docker compose up
```

Open <http://localhost:8443> (`user` / `password`). The interval is 30s and the
quota 200M, so every guard trips while you are still watching.

## Things to try

```bash
# 1. hard kill — costs at most one interval
docker kill disposable-desktop && docker compose up -d

# 2. two containers on one prefix — the second is refused
docker compose --profile conflict up intruder

# 3. wipe most of the home directory on the desktop — the save refuses,
#    and PERSISTENCE-WARNING.txt appears in the user's home

# 4. blow the quota
docker exec -u 1000 disposable-desktop fallocate -l 300M /home/user/big.bin

# 5. recover something a sync removed
docker exec disposable-minio \
  mc ls --recursive d/qgis-homes/disposable-9a4f/.persist-trash/
```

`docker compose down` (without `-v`) destroys the desktop and keeps the bucket —
which is the whole point.

## Taking it to Kubernetes

| Here | There |
|------|-------|
| `hostname: qgis-desktop-0` | A **StatefulSet** — stable pod identity is the lease identity |
| `stop_grace_period: 60s` | `terminationGracePeriodSeconds: 60`, or the final save is killed |
| Keys in the environment | A mounted `Secret` plus the `_FILE` variables |
| One prefix | One replica per user |

Full write-up: [`docs/scenarios/disposable-pod.md`](../../docs/scenarios/disposable-pod.md)
