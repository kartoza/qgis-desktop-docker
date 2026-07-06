# License

QGIS Desktop Docker is licensed under the **GNU General Public License
version 2.0 (GPL-2.0)**. See the
[`LICENSE`](https://github.com/kartoza/qgis-desktop-docker/blob/main/LICENSE)
file at the root of the repository for the full text.

## Bundled software

The container ships third-party software, each under its own licence:

| Component | Licence | Notes |
|-----------|---------|-------|
| QGIS | GPL-2.0 | <https://qgis.org> |
| KasmVNC | GPL-2.0 | <https://kasmweb.com>, packaged from the Debian Bookworm `.deb`. |
| XFCE (session, panel, terminal, desktop, wm, settings, xfconf, thunar) | GPL-2.0 / LGPL-2.1 | <https://xfce.org> |
| Nixpkgs-provided base (bash, coreutils, glibc, nftables, util-linux, etc.) | Various OSI-approved | See the SBOM attached to each release for exact per-package licences. |

For a complete, versioned list of every package in the image and its
licence, consult the SPDX SBOM attached to the corresponding release
(`sbom.spdx.json`).

## Trademarks

QGIS is a trademark of the QGIS.org project. KasmVNC and Kasm Workspaces
are trademarks of Kasm Technologies Inc. This project is not affiliated
with, endorsed by, or sponsored by either.

Made with love by [Kartoza](https://kartoza.com) —
[Donate!](https://github.com/sponsors/kartoza) —
[GitHub](https://github.com/kartoza/qgis-desktop-docker).
