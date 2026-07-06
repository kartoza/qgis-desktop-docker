# About

QGIS Desktop Docker is a small project with one goal: let anyone run QGIS
from a browser tab, without installing QGIS on their machine and without
handing over shell access to a server.

It is built with [Nix](https://nixos.org/) so the whole image — every
library, every version — is declared in a flake and produced
byte-identically on any machine that builds it. The image ships with an
nftables egress firewall and HTTP BasicAuth on by default; loosening
either is opt-in.

The project is maintained by [Kartoza](https://kartoza.com), an open-source
geospatial consultancy.

## About this documentation

- [Specification](specification.md) — pointer to `SPECIFICATION.md` (when
  it exists).
- [Sponsors](sponsors.md) — how to fund ongoing work.
- [License](license.md) — GPL-2.0 and the licences of the bundled
  software.

Made with love by [Kartoza](https://kartoza.com) —
[Donate!](https://github.com/sponsors/kartoza) —
[GitHub](https://github.com/kartoza/qgis-desktop-docker).
