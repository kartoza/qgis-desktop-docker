# Nix workflow

The flake exposes a set of `nix run .#*` targets that cover the common
build/run/demo flows. All of them pass `--cap-add=NET_ADMIN` so the
entrypoint can install the nftables egress filter.

## Targets

| Target | What it does |
|--------|--------------|
| `nix run` | Print the help banner listing every target. |
| `nix run .#build-docker` | Build the image with `nix build .#docker` and load it into the local Docker daemon as `nix-xfce-kasm:latest`. Prints the image size at the end. |
| `nix run .#run` | Foreground run with the default single-user auth. Log in as `user` / `password`. |
| `nix run .#run-multi-user` | Foreground run with `KASM_USERS='alice:pw1,bob:pw2'` set. |
| `nix run .#run-users-file` | Foreground run that generates a temp `user:password` file, mounts it at `/etc/kasmvnc/users:ro`, and cleans it up on exit. |
| `nix run .#run-no-auth` | Foreground run with `KASM_AUTH=0`. No prompt, no auth. Dev only. |
| `nix run .#run-greeter` | LightDM greeter inside the desktop. Log in as `user` / `password`. |
| `nix run .#run-greeter-multi` | Greeter mode with `alice` and `bob` as real Linux accounts. |
| `nix run .#run-oidc` | Single sign-on against your own identity provider. Reads `KASM_OIDC_ISSUER_URL`, `KASM_OIDC_CLIENT_ID` and `KASM_OIDC_CLIENT_SECRET` from your shell and refuses to start without them. |
| `nix run .#run-keycloak-demo` | Throwaway Keycloak with a pre-imported realm plus the SSO desktop. Needs a `127.0.0.1 keycloak` hosts entry — see [Keycloak SSO](../scenarios/keycloak-sso.md). |
| `nix run .#test` | Run every check that needs no Docker. |
| `nix run .#test-oidc` | Unit-test the OIDC plumbing. No Docker, no identity provider, a couple of seconds. |
| `nix run .#test-terminal-lockdown` | Unit-test `KASM_ALLOW_TERMINAL=0` against a throwaway tree. |
| `nix run .#run-locked-down` | Auth on plus full DLP: clipboard blocked, watermark, DLP `info` log, 500 ms clipboard delay. |
| `nix run .#run-egress-locked` | Demo egress allowlist (`1.1.1.1`, `example.com`). Everything else is dropped. |
| `nix run .#run-no-lockdown` | Auth off **and** egress lockdown off. Full-open dev mode; do not expose. |
| `nix run .#run-analyst-scenario` | End-to-end scenario: `bob` / `password123`, clipboard blocked, watermark, egress restricted to a co-located `postgis/postgis` DB. See [Analyst locked-down session](../scenarios/analyst-locked-down.md). |
| `nix run .#stop` | Remove the running `qgis-desktop` container. |
| `nix run .#logs` | Follow the container logs (`docker logs -f qgis-desktop`). |
| `nix run .#summary` | Regenerate `build-summary.md` (image size, SBOM table, CVE table). |

Building blocks, for when you only want one piece:

| Target | What it does |
|--------|--------------|
| `nix build .#epanet` | Build the EPANET solver. Solves a bundled network as part of the build. |
| `nix build .#swmm` | Build the SWMM solver. Routes a one-pipe model as part of the build. |
| `nix build .#qgis` | QGIS with the Giswater Python packages and both solvers wrapped in. |

## Dev shell

```bash
nix develop
```

Provides `docker`, `python3`, `syft`, `grype`, and `jq`. The shell hook
prints the same target list as `nix run`.

!!! note
    The `run-*` targets all remove any existing `qgis-desktop` container
    first, so you can rerun them without a manual `docker rm`. Only one
    container of that name can be running at a time.
