# Developer guide

Documentation for anyone modifying the image, the flake, or the
entrypoint scripts.

- [Nix flake](nix-flake.md) — structure of `flake.nix`, the derivations it
  builds, and the `mkApp` helper behind `nix run .#*`.
- [Architecture](architecture.md) — the container boot flow from PID 1 as
  root down to QGIS running as UID 1000.
- [Project structure](project-structure.md) — annotated tree of the repo.
- [Contributing](contributing.md) — PR conventions, branch naming,
  versioning.
