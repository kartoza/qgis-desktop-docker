# Delivering data through the bucket

Someone needs a dataset in their session. They are in a locked-down desktop with
no terminal, and you would rather not `docker exec` into a running container or
restart it under them. So you put the file in their bucket, and it arrives.

![provision/ and inbox/, and what each one is for](diagrams/team-data-drop.svg)

## Two prefixes, two different jobs

Under each user's prefix the container reads three places, and treats them
differently on purpose.

| Prefix | When it arrives | Conflict with the user's copy | Afterwards |
|--------|-----------------|-------------------------------|------------|
| `provision/` | Every container start | **User wins** — existing files are skipped | Stays in the bucket |
| `inbox/` | Every interval, while running | **Delivery wins** — existing files are overwritten | Deleted from the bucket |
| `home/` | Restored at start, saved back continuously | It *is* the user's copy | Stays |

The distinction matters more than it looks:

- `provision/` is **standard issue** — a starter project, house styles, a
  basemap definition. It is idempotent, so it is safe to leave forever, and it
  never clobbers work. If a user edits the issued project, their version stands.
- `inbox/` is a **hand-off** — "here is the survey you asked for". It is
  delivered once and removed, so the user isn't handed the same file every
  minute, and a stale copy can't reappear after they delete it.

Getting this backwards is the common mistake: putting a one-off delivery in
`provision/` means the user can never get rid of it, and putting a baseline in
`inbox/` means it lands on their Desktop once and is gone from the bucket.

## Run it

```bash
nix run .#build-docker
nix run .#run-data-drop-scenario
```

Open **<http://localhost:8443>** (`user` / `password`). QGIS opens on the
provisioned project. About a minute later a dispatcher drops `assets.csv` into
`inbox/` and it appears on the desktop — the scenario includes that second step
so you can watch a delivery land on a session that is already running.

MinIO's console is at <http://localhost:9001> (`minioadmin` / `minioadmin123`);
browse `qgis-homes/surveyor-7c1e/` to see the three prefixes side by side.

## Delivering to a real user

Any S3 client works, because the container is only reading a prefix:

```bash
# a baseline for everyone on the team
for user in surveyor-7c1e analyst-3f88 gis-lead-a201; do
  aws s3 cp --recursive ./kit/ "s3://qgis-homes/${user}/provision/"
done

# a one-off, to one person, right now
aws s3 cp ./ward-7-parcels.gpkg s3://qgis-homes/surveyor-7c1e/inbox/
```

Nothing needs to restart. The next interval picks it up.

## What stops this being an attack surface

Delivery writes into a home directory on behalf of a user who never sees the
credentials. Three things keep that honest:

| Concern | What happens |
|---------|--------------|
| Files land as root and the user can't touch them | The staging copy drops to uid 1000 via `setpriv`, so everything delivered is owned by the user |
| A crafted path escapes the home directory | The copy runs unprivileged and rclone writes into a staging directory first — a `../` in an object key cannot land outside `$HOME` |
| The staging directory leaks the operator's files | It is created `0755` root-owned, with the config-writing `umask 077` scoped to a subshell so it can't leak — there is a regression test for exactly this |
| The user reads the credentials to fetch other prefixes | They are root-owned `0400` and scrubbed from the environment before the desktop starts |
| A delivery fills the disk | It counts against `QGIS_DESKTOP_PERSIST_QUOTA` like anything else |

## Verification checklist

| Test | Expected |
|------|----------|
| `docker logs data-drop-desktop \| grep Provisioning` | `Provisioning 3 file(s) from provision/` at start |
| Edit `~/projects/survey.qgs`, restart the container | Your edit survives — provisioning skips existing files |
| `mc cp x.gpkg demo/qgis-homes/surveyor-7c1e/inbox/` | Appears in `~/Desktop` within one interval, and disappears from `inbox/` |
| `ls -l ~/Desktop/assets.csv` on the desktop | Owned by `user`, not `root` |
| `docker exec -u 1000 data-drop-desktop env \| grep KEY` | Nothing |

## Turning it off

Both paths are on by default. Either can be disabled independently:

```bash
QGIS_DESKTOP_PERSIST_PROVISION=0     # no baseline
QGIS_DESKTOP_PERSIST_INBOX=0         # no mid-session delivery
QGIS_DESKTOP_PERSIST_INBOX_DEST=Downloads   # default: Desktop
```

## See also

- [Home persistence](../configuration/persistence.md) — the sync itself, the guards, the quota
- [Persistent workstation](persistent-workstation.md) — the same storage, one user, no delivery
- [SSO + persistent homes](sso-persistent-homes.md) — delivering to people who sign in with SSO
