# QGIS Desktop Docker

!!! quote ""
    *Putting spatial decision-making tools in the hands of everyone.*

A fully reproducible, Nix-built Docker image that runs QGIS inside a minimal
XFCE desktop, reachable from any web browser via KasmVNC — no VNC client, no
local install, no shell access.

The container ships secure-by-default: HTTP BasicAuth on the web endpoint,
clipboard sharing off in both directions, and an nftables egress firewall
that fails closed if it cannot be enforced. Every build produces an SPDX
SBOM and a Grype CVE scan as release artefacts.

## What it gives you

- A full QGIS 4.0 desktop in a browser tab, on any device.
- Multi-monitor and dynamic resolution via KasmVNC.
- **Four auth pathways** (choose per deployment via `KASM_AUTH_MODE`):
  the browser's HTTP BasicAuth dialog (`basic`, default), a LightDM
  greeter *inside* the desktop that re-prompts cleanly on failure
  (`greeter`), Keycloak/OIDC single sign-on in front of the desktop
  (`oidc`), or no auth for local dev (`none`). File- or env-based
  multi-user credentials work with all but `oidc`, which takes its accounts
  from your identity provider.
- **Giswater-ready QGIS**: the EPANET and SWMM hydraulic solvers built from
  source, the Python packages the plugin imports, and the `epa` command that
  makes Giswater find the solvers on Linux.
- Data-loss-prevention knobs: clipboard direction and size caps, MIME
  allowlist, screen watermark, DLP audit log.
- An nftables egress lockdown with a hostname/CIDR allowlist that runs
  before the desktop and drops all outbound traffic that is not on the list.
- Reproducible builds: the whole image is defined by a Nix flake, so two
  builds on two machines produce a byte-identical artefact.
- SBOM (`sbom.spdx.json`) and CVE scan (`cve-scan.json`) attached to every
  release and PR build.

## Where to next

- [Quick start](getting-started/quickstart.md) — pull, run, log in.
- [Configuration](configuration/index.md) — every environment variable and
  what it does.
- [Scenarios](scenarios/index.md) — worked deployments combining the knobs.

!!! tip
    New to Nix? You do not need it to run the image — pull from GHCR and
    use `docker run`. Nix is only required to build from source.
