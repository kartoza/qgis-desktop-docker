<!--
SPDX-FileCopyrightText: Kartoza
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Security

This image runs a full XFCE desktop with QGIS, reached over the web through
KasmVNC. The person using it is assumed to be able to run **arbitrary code**
inside the container — QGIS ships a Python console, and that is an
arbitrary-code path even when the terminal is removed
(`QGIS_DESKTOP_ALLOW_TERMINAL=0`). Every control below is designed around that
assumption: the goal is that a hostile desktop user cannot reach the host or
another tenant, not that they cannot run code in their own session.

## Reporting a vulnerability

Please report privately through GitHub Security Advisories
("**Report a vulnerability**" on the repository's **Security** tab) rather than
opening a public issue. We aim to acknowledge within a few working days.

## The isolation model, in one paragraph

The container starts as root **only** long enough to install the egress
firewall and prepare its runtime directories, then `setpriv` drops it to
unprivileged users and clears every inheritable and ambient capability:

- the **desktop, X server and QGIS** run as uid **1000**;
- the **OIDC proxy**, when enabled, runs as its own system uid **997**, so the
  desktop cannot read the client secret (the file is `0400`, owned by 997);
- there are **no setuid or setgid binaries** anywhere in the image, and no
  `sudo`, `su`, `pkexec` or `doas`. With nothing to escalate through, the
  uid-1000 session holds **zero effective capabilities** (`CapEff=0`).

## Container-escape audit

The techniques in the widely-circulated "Linux Docker Container Escapes"
cheatsheet were each checked against this image, run the way the shipped
`docker-compose.yml` files run it (`cap_drop: ALL`, `cap_add: NET_ADMIN` only,
`no-new-privileges`). None of them succeed, because every one needs a privilege
the container is never granted — and, for several, tooling the image does not
contain.

| Escape technique | Requires | Status here |
|---|---|---|
| Mounted Docker socket | `docker.sock` bind-mounted in | Not mounted by any example; no `docker` CLI in the image |
| `CAP_SYS_ADMIN` → mount the host disk | `SYS_ADMIN` | Not granted, and absent from the bounding set; `mount` returns `EPERM` |
| `CAP_SYS_ADMIN` → cgroup `release_agent` | `SYS_ADMIN` | Same; `unshare`/`mount` return `EPERM` |
| Shared host namespaces → `nsenter` | `--pid=host` etc. + `SYS_ADMIN` | No shared namespaces; `nsenter --target 1` returns `EPERM` |
| `CAP_SYS_PTRACE` → shellcode injection | `SYS_PTRACE` + shared ns | Not granted; absent from the bounding set; no compiler in the image |
| `CAP_SYS_PTRACE` → `gdb` injection | `SYS_PTRACE` + `gdb` | Not granted; no `gdb` in the image |
| `CAP_SYS_MODULE` → load a kernel module | `SYS_MODULE` | Not granted; absent from the bounding set; no `insmod`/`kmod` in the image |
| `--privileged` | the privileged flag | Never used by any example or `nix run` demo |

The three capabilities these escapes turn on — `SYS_ADMIN`, `SYS_PTRACE`,
`SYS_MODULE` — are absent even from the container's capability **bounding
set**, so they cannot be reacquired during the brief root phase either.

## Why the examples keep a `cap_add` at all

The one capability added over Docker's already-reduced default is
**`NET_ADMIN`**, and only so the entrypoint can install the nftables **egress
firewall** (see [egress lockdown](docs/configuration/egress-lockdown.md)). It is
cleared from the desktop session by the same `setpriv` drop, so the signed-in
user cannot alter the firewall. `NET_ADMIN` is not one of the escape vectors
above. Drop it only if you also set `QGIS_DESKTOP_EGRESS_LOCKDOWN=0`, or the
container refuses to start.

## The capability set the examples use

The example compose files do not merely rely on Docker's defaults — they
**drop every capability and add back only the ten this image actually uses**.
This is an allowlist on purpose: if a future base image widens Docker's default
set, this container does not inherit the addition.

| Capability | Why it is needed |
|---|---|
| `CHOWN` | chown runtime directories to the desktop (1000) and proxy (997) uids |
| `DAC_OVERRIDE` | write across owners — runtime dirs, and the OIDC secret file |
| `FOWNER` | chmod / set timestamps on files the root phase does not own |
| `FSETID` | preserve setgid bits when creating directories |
| `SETUID` | `setpriv` drops root to uid 1000 / 997 |
| `SETGID` | `setpriv` drops the gid and initialises supplementary groups |
| `SETPCAP` | `setpriv` clears the inheritable / ambient capability sets |
| `KILL` | the session supervisor reaps the desktop process tree |
| `AUDIT_WRITE` | PAM records the login uid when signing in (greeter mode) |
| `NET_ADMIN` | install the nftables egress filter |

Dropped for good, relative to Docker's default set: `NET_RAW`, `MKNOD`,
`SYS_CHROOT`, `SETFCAP`, `NET_BIND_SERVICE`.

Alongside the caps, every example sets `security_opt: ["no-new-privileges:true"]`
so no process can acquire privileges beyond those it starts with. Because the
image ships no setuid binaries, this simply nails the door shut.

## What is your responsibility, not the image's

An image cannot stop an operator from handing it privileges. **Do not** run this
container with any of the following unless you fully understand the consequence —
each one reopens a row in the table above:

- `--privileged`
- `--cap-add=SYS_ADMIN`, `--cap-add=SYS_PTRACE`, or `--cap-add=SYS_MODULE`
- a bind mount of `/var/run/docker.sock` (or any host Docker/containerd socket)
- `--pid=host`, `--network=host`, or other shared host namespaces
- bind mounts of sensitive host paths (`/`, `/proc`, `/sys`, `/dev`, `/root`)

None of the shipped examples do any of these. Keep it that way in your own
deployment and the escape audit above continues to hold.
