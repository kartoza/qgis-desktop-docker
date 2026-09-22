# Installing Nix

Only needed if you're building the image yourself ([Building from
source](building.md)) or using the [Nix workflow](nix-workflow.md) targets.
Pulling the published image (`ghcr.io/kartoza/qgis-desktop-docker:ltr`) needs
no Nix at all, skip this page if that's all you're doing.

## Which version

Nothing here is pinned to a specific Nix release. CI itself
(`cachix/install-nix-action`) installs whatever is current, no version input
set. Install the latest stable Nix and you'll match CI. The two features this
flake actually depends on:

- **Flakes** (the `nix-command` and `flakes` experimental features), stable
  since Nix 2.4.
- **`builtins.fetchGit` with `submodules = true`**, also since Nix 2.4, used
  to vendor the Giswater plugin source.

Anything reasonably current satisfies both.

## Install

### Official installer

```bash
curl -L https://nixos.org/nix/install | sh -s -- --daemon
```

Multi-user (daemon) mode, matching what CI uses. Needs `sudo`, it creates
`/nix` and a handful of build-user accounts. Restart your shell afterwards.

### Determinate Nix Installer

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

A hardened installer from [Determinate Systems](https://determinate.systems/)
that also defaults to multi-user mode. Enables flakes out of the box (see
below), and is easier to uninstall cleanly than the official one if you ever
need to.

Either works. If you're on NixOS already, you have Nix, skip this page
entirely.

!!! warning "Needs `sudo`, once"
    Both installers need root to create `/nix` and the build-user accounts
    for multi-user mode. There is a single-user install path that avoids
    this, but it's deprecated on Linux and more likely to fail partway
    through, go multi-user unless you have a specific reason not to.

## Enable flakes

The Determinate installer turns flakes on by default. With the official
installer, add this yourself:

```bash
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

Restart your shell (or `source`/re-open your terminal) so `PATH` picks up
`nix`.

## Verify

```bash
nix --version
```

Then, from a checkout of this repo:

```bash
nix flake check       # evaluates the flake, fast, no build
nix run .#test         # runs the no-Docker-needed test suite
```

If both succeed, you're ready for [Building from source](building.md).

!!! tip "Slow first build"
    The first real build (`nix build .#docker` / `nix run .#build-docker`)
    fetches and builds a lot, expect it to take a while and pull a
    meaningful amount of data, even with the [Nix community binary
    cache](https://cache.nixos.org) doing most of the work. Subsequent
    builds are much faster; only what actually changed gets rebuilt.

## Docker still required

Nix builds the image; it does not run it. You still need Docker installed
and running to `docker load` the result and start a container, see
[Building from source](building.md).
