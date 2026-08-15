---
hide:
  - navigation
  - toc
---
<!-- SPDX-FileCopyrightText: Kartoza -->
<!-- SPDX-License-Identifier: GPL-2.0-or-later -->

<div class="kz-hero" markdown>

<span class="kz-eyebrow">KARTOZA &middot; QGIS DESKTOP DOCKER</span>

# QGIS in a browser tab, locked down by default

A full QGIS desktop over the web &mdash; four ways to sign in, an egress firewall
that fails closed, and a home directory that outlives the container.

<div class="kz-cta" markdown>
[:material-rocket-launch: Quick start](getting-started/quickstart.md){ .kz-cta__primary }
[:material-tune: Configuration](configuration/index.md){ .kz-cta__secondary }
[:simple-github: GitHub](https://github.com/kartoza/qgis-desktop-docker){ .kz-cta__secondary }
</div>

</div>

## Pull it

Two tags on one image. Same container, same settings &mdash; the QGIS inside is
the only difference.

<div class="grid cards" markdown>

-   :material-shield-check:{ .lg .middle } __QGIS 3.44.9 LTR__

    ---

    The long-term release: bug fixes only, so a project that opens today opens
    the same way next month. This is the one to put in front of users, and what
    `:latest` points at.

    ```bash
    docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
      ghcr.io/kartoza/qgis-desktop-docker:qgis-ltr
    ```

-   :material-flask-outline:{ .lg .middle } __QGIS 4.0.1__

    ---

    The current release, which becomes the next LTR. Open your real projects
    against it now, while a regression can still be reported upstream rather
    than discovered on the day the LTR ships.

    ```bash
    docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
      ghcr.io/kartoza/qgis-desktop-docker:qgis-latest
    ```

</div>

Then open <http://localhost:8443> and sign in as `user` / `password`. Everything
else is an environment variable &mdash; see
[Configuration](configuration/index.md).

## What's in the box

<div class="grid cards" markdown>

-   :material-monitor-screenshot:{ .lg .middle } __A desktop, not a viewer__

    ---

    KasmVNC serves the whole XFCE session to a browser tab. No VNC client, no
    local install, multi-monitor and dynamic resizing included.

    [:octicons-arrow-right-24: Quick start](getting-started/quickstart.md)

-   :material-account-key:{ .lg .middle } __Four ways to sign in__

    ---

    No auth, the browser's HTTP Basic dialog, a LightDM greeter inside the
    desktop, or Keycloak/OIDC single sign-on with an authenticating proxy in
    front of the whole thing.

    [:octicons-arrow-right-24: Authentication](configuration/authentication.md)

-   :material-content-save-cog:{ .lg .middle } __Homes that outlive the container__

    ---

    Restored from object storage before the desktop starts, saved on an
    interval and again on shutdown. Delete the container, start another, and
    the user's projects are still there.

    [:octicons-arrow-right-24: Home persistence](configuration/persistence.md)

-   :material-shield-lock:{ .lg .middle } __Egress locked by default__

    ---

    An nftables allowlist installed before the desktop starts, by a root
    entrypoint that then drops its own capabilities. No allowlist means no
    outbound traffic, and a container that cannot enforce it refuses to run.

    [:octicons-arrow-right-24: Egress lockdown](configuration/egress-lockdown.md)

-   :material-eye-off:{ .lg .middle } __Data-loss controls__

    ---

    Clipboard blocked in both directions unless you say otherwise, size caps
    and MIME allowlists, a screen watermark, DLP audit logging, and a switch
    that removes terminal access entirely.

    [:octicons-arrow-right-24: Permissions](configuration/permissions.md)

-   :material-water-pump:{ .lg .middle } __Giswater-ready QGIS__

    ---

    EPANET and SWMM built from upstream source &mdash; each solves a real model
    during the build &mdash; plus the Python packages the plugin imports, inside
    QGIS's own interpreter.

    [:octicons-arrow-right-24: Giswater](configuration/giswater.md)

-   :material-snowflake:{ .lg .middle } __Reproducible by construction__

    ---

    One Nix flake defines the whole image, so two builds on two machines
    produce the same artefact. Every release ships an SPDX SBOM and a Grype
    CVE scan.

    [:octicons-arrow-right-24: Building from source](getting-started/building.md)

-   :material-file-tree:{ .lg .middle } __Worked deployments__

    ---

    A locked-down analyst session with a co-located PostGIS, a shared
    workstation with per-user logins, and single sign-on against a throwaway
    Keycloak you can run in one command.

    [:octicons-arrow-right-24: Scenarios](scenarios/index.md)

</div>

## Status

[![Docker](https://github.com/kartoza/qgis-desktop-docker/actions/workflows/docker.yml/badge.svg)](https://github.com/kartoza/qgis-desktop-docker/actions/workflows/docker.yml)
[![Docs](https://github.com/kartoza/qgis-desktop-docker/actions/workflows/docs.yml/badge.svg)](https://github.com/kartoza/qgis-desktop-docker/actions/workflows/docs.yml)
[![QGIS](https://img.shields.io/badge/QGIS-3.44%20LTR%20%7C%204.0-green?logo=qgis)](configuration/index.md)
[![KasmVNC](https://img.shields.io/badge/KasmVNC-1.4-blue)](https://kasmweb.com)
[![Built with Nix](https://img.shields.io/badge/Built%20with-Nix-5277C3?logo=nixos)](getting-started/building.md)
[![License](https://img.shields.io/badge/License-GPL--2.0-orange)](about/license.md)

Every pull request builds both QGIS channels, smoke-tests the desktop, and runs
the test suite before either image is published.

<div class="kz-footer-credits" markdown>
Made with love by [Kartoza](https://kartoza.com) &middot;
[Sponsor on GitHub](https://github.com/sponsors/kartoza) &middot;
[Repository](https://github.com/kartoza/qgis-desktop-docker)
</div>
