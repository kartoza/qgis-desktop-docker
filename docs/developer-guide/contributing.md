# Contributing

Small, focused pull requests are always welcome.

## Workflow

1. Fork the repo on GitHub and clone your fork.
2. Create a feature branch from `main`:

    ```bash
    git checkout -b feature/short-description
    ```

3. Make your change. Keep unrelated cleanups out of the same PR.
4. If your change addresses a GitHub issue, reference it in the commit
   message and the PR description using GitHub's `fixes #N` syntax so the
   issue auto-closes on merge.
5. Open a PR against `kartoza/qgis-desktop-docker:main`. The CI workflow
   will build the image, generate the SBOM and CVE scan, and post a build
   report comment on the PR.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

```text
feat(egress): allow CIDR notation in QGIS_DESKTOP_EGRESS_ALLOW

fix(auth): trim trailing whitespace in QGIS_DESKTOP_USERS entries

docs(configuration): clarify watermark ${USER} expansion
```

The prefix drives the version bump.

## Versioning

Semver, driven by commit types:

| Commit type | Bump |
|-------------|------|
| `fix` only | Patch (`0.1.0` → `0.1.1`) |
| Any `feat` | Minor (`0.1.0` → `0.2.0`) |
| Any `BREAKING CHANGE:` footer | Major (`0.1.0` → `1.0.0`) |

## Before you push

- Rebuild the image locally with `nix run .#build-docker` and confirm it
  starts.
- If you touched `entrypoint.sh` or `start-desktop.sh`, run at least one
  `nix run .#run-*` target end-to-end.
- Do not commit hard-coded absolute paths that only exist on your machine.
- Do not commit lockfile bumps in the same PR as feature changes —
  lockfile updates get their own PR.

!!! note
    The project ships GPL-2.0. By opening a PR you agree your contribution
    is licensed under the same terms.
