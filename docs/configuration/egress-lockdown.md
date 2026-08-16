# Egress lockdown

The container ships with an **egress firewall enabled by default**. On
startup a root entrypoint installs nftables rules that drop all outbound
traffic except an explicit allowlist, then drops all capabilities and
switches to UID 1000 so the desktop process cannot alter the firewall.

## What is allowed by default

- Loopback traffic (`oif "lo"`).
- Return traffic for connections the container initiated
  (`ct state established,related`).
- DNS to Docker's embedded resolver (`127.0.0.11`, both UDP and TCP on 53)
  and any nameserver listed in `/etc/resolv.conf`.
- Every host, CIDR, or hostname you name in `QGIS_DESKTOP_EGRESS_ALLOW`.

Everything else outbound is dropped.

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `QGIS_DESKTOP_EGRESS_LOCKDOWN` | `1` | `0` disables the filter entirely. **Dev only.** |
| `QGIS_DESKTOP_EGRESS_ALLOW` | *(empty)* | Comma-separated allowlist: IPv4 addresses, CIDRs, and/or hostnames. Hostnames are resolved once at startup. |

## Required capability

The entrypoint calls `nft`, which needs `NET_ADMIN`:

```bash
docker run --cap-add=NET_ADMIN -p 8443:8443 ...
```

```yaml
services:
  qgis-desktop:
    cap_add:
      - NET_ADMIN
```

!!! danger "Fail closed"
    If `NET_ADMIN` is missing and `QGIS_DESKTOP_EGRESS_LOCKDOWN=1` (the default)
    the container refuses to start. It prints a diagnostic pointing at the
    fix and exits non-zero. Setting `QGIS_DESKTOP_EGRESS_LOCKDOWN=0` opts out — do
    this only in local dev.

## Example: only a Postgres DB reachable

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -e QGIS_DESKTOP_EGRESS_ALLOW='db.internal,10.0.0.0/24' \
  ghcr.io/kartoza/qgis-desktop-docker:ltr
```

Inside the desktop `psql -h db.internal ...` works;
`curl https://example.com` hangs and times out.

For a full worked example with a co-located PostGIS container see
[Analyst locked-down session](../scenarios/analyst-locked-down.md).

## Caveats

!!! warning "Hostnames resolved once"
    Hostnames in `QGIS_DESKTOP_EGRESS_ALLOW` are resolved **once at container
    start** via `getent ahostsv4`. If the target's IP changes (typical for
    cloud-managed databases and Docker service IPs on network restarts),
    restart the container to re-resolve.

!!! warning "IPv4 only"
    Only IPv4 is filtered. If you use IPv6, either add rules to
    `entrypoint.sh` or block IPv6 entirely with
    `--sysctl net.ipv6.conf.all.disable_ipv6=1`.

!!! note "Per-container filter"
    The filter runs inside the container's own network namespace, so it
    does not restrict traffic between multiple containers on a shared
    Docker network — unless each container has its own filter.

## How the drop happens

The entrypoint installs a table of its own, `inet qgis_desktop_egress`, whose output
chain is `policy drop` plus `accept` rules for loopback, established traffic,
DNS and the allowlist. After the ruleset is installed, `setpriv` clears
`NET_ADMIN` from the inheritable and ambient sets before it execs
`start-desktop`. From that point on, `nft` inside the desktop returns
`Operation not permitted`, even though the container was launched with
`--cap-add=NET_ADMIN`.

```bash
docker exec <container> nft list table inet qgis_desktop_egress
```

!!! note "Only our own table is replaced"
    The rules go into `inet qgis_desktop_egress`, and only that table is deleted and
    recreated on boot. Flushing the whole ruleset would also delete Docker's
    `ip nat` table — the one holding the DNAT rules that make the embedded
    resolver at `127.0.0.11:53` answer at all — and nftables labels that table
    "managed by iptables-nft, do not touch". Releases before 2.0.0 flushed it,
    which broke *all* name resolution inside the container on user-defined and
    Compose networks, allowlisted or not.
