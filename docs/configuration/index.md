# Configuration

Every knob is an environment variable, grouped by concern.

| Group | What it controls | Page |
|-------|------------------|------|
| Session | Port, resolution, colour depth, X display number. | [Environment](environment.md) |
| Kasm permissions | Clipboard direction, size caps, MIME allowlist, watermark, DLP audit log. | [Kasm permissions](kasm-permissions.md) |
| Authentication | HTTP BasicAuth, multi-user via file or env, disabling auth. | [Authentication](authentication.md) |
| Egress lockdown | nftables allowlist, fail-closed behaviour, capability requirement. | [Egress lockdown](egress-lockdown.md) |

Defaults are chosen so that a stock `docker run --cap-add=NET_ADMIN`
produces a container that is safe to expose on a local network: auth on,
clipboard off, egress dropped. Every relaxation is opt-in.

!!! note "Booleans"
    Boolean variables (`KASM_AUTH`, `KASM_ALLOW_CLIPBOARD_IN`, etc.)
    accept `1`, `yes`, `true`, `on`, or `enabled` for true. Anything else
    counts as false.
