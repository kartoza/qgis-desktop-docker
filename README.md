# QGIS Desktop Docker

A fully reproducible, Nix-built Docker image that runs [QGIS](https://qgis.org) inside a minimal XFCE desktop, accessible from any web browser via [KasmVNC](https://kasmweb.com). No VNC client needed -- just open a URL.

![QGIS 4.0](https://img.shields.io/badge/QGIS-4.0-green?logo=qgis)
![KasmVNC 1.4](https://img.shields.io/badge/KasmVNC-1.4-blue)
![Built with Nix](https://img.shields.io/badge/Built%20with-Nix-5277C3?logo=nixos)
![License](https://img.shields.io/badge/License-GPL--2.0-orange)

## Features

- **Browser-based access** -- connect to a full QGIS desktop from any device with a web browser
- **Multi-monitor support** -- KasmVNC supports dynamic resolution resizing and multiple monitors
- **Fully reproducible** -- the entire image is defined declaratively in a Nix flake
- **Persistent workspaces** -- mount a volume to keep your QGIS projects, plugins, and settings across restarts
- **Minimal footprint** -- only the packages needed to run QGIS and the desktop environment
- **No auth by default** -- designed for local use; add authentication for production deployments

## Quick Start

### Using Docker

```bash
docker run --rm -p 8443:8443 ghcr.io/kartoza/qgis-desktop-docker:latest
```

Open [http://localhost:8443](http://localhost:8443) in your browser.

### Using Docker Compose

```bash
curl -O https://raw.githubusercontent.com/kartoza/qgis-desktop-docker/main/docker-compose.yml
docker compose up -d
```

Open [http://localhost:8443](http://localhost:8443) in your browser.

## Usage Examples

### Basic (ephemeral)

```bash
docker run --rm -p 8443:8443 ghcr.io/kartoza/qgis-desktop-docker:latest
```

Everything is lost when the container stops.

### Persistent home directory (named volume)

```bash
docker run --rm -p 8443:8443 \
  -v qgis-home:/home/user \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

QGIS settings, plugins, and projects in `/home/user` survive container restarts.

### Bind mount a local directory

```bash
docker run --rm -p 8443:8443 \
  -v "$HOME/qgis-data:/home/user/data" \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

Your local `~/qgis-data` folder appears at `/home/user/data` inside the container. Useful for working with shapefiles, GeoPackages, and rasters on the host.

### Persistent home + local data

```bash
docker run --rm -p 8443:8443 \
  -v qgis-home:/home/user \
  -v "$HOME/gis-projects:/home/user/projects" \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

### Custom resolution

```bash
docker run --rm -p 8443:8443 \
  -e VNC_RESOLUTION=1920x1080 \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

### Custom port

```bash
docker run --rm -p 3000:3000 \
  -e VNC_PORT=3000 \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

Then open [http://localhost:3000](http://localhost:3000).

## Docker Compose

The included `docker-compose.yml` provides a production-ready configuration with persistent storage:

```yaml
services:
  qgis-desktop:
    image: ghcr.io/kartoza/qgis-desktop-docker:latest
    container_name: qgis-desktop
    ports:
      - "8443:8443"
    environment:
      - VNC_RESOLUTION=1920x1080
      - VNC_COL_DEPTH=24
      - VNC_PORT=8443
    volumes:
      # Persist the user's home directory
      - qgis-home:/home/user
      # Optional: mount a local data directory
      # - ./data:/home/user/data
    restart: unless-stopped

volumes:
  qgis-home:
```

```bash
# Start
docker compose up -d

# Stop
docker compose down

# Stop and remove persistent data
docker compose down -v
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VNC_PORT` | `8443` | Port for the KasmVNC web interface |
| `VNC_RESOLUTION` | `1280x720` | Initial desktop resolution (resizable in browser) |
| `VNC_COL_DEPTH` | `24` | Color depth (16, 24, or 32) |
| `VNC_PW` | `password` | VNC password (only used for kasmvncpasswd, basic auth is disabled) |
| `DISPLAY` | `:1` | X display number |

## Architecture

This image is built entirely with [Nix](https://nixos.org), using `dockerTools.buildLayeredImage` for reproducible, minimal Docker images.

```
flake.nix                    # Main flake: defines packages, Docker image, dev shell
kasmvnc.nix                  # KasmVNC package (v1.4.0 from Debian Bookworm deb)
libcrypt-compat.nix          # libcrypt.so.1 compat lib from Debian
start-desktop.sh             # Entrypoint: launches Xkasmvnc + XFCE
config/                      # XFCE panel and desktop configuration
  xfce4/panel/default.xml
  xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml
docker-compose.yml           # Docker Compose example
build-summary.sh             # Build summary and SBOM generator
.github/workflows/
  pr-build.yml               # PR: build, artifact (7d), comment summary
  release.yml                # Release: build, publish to GHCR, attach assets
```

### How it works

1. **Xkasmvnc** starts an X server with an embedded web server and VNC protocol
2. **XFCE** launches inside the X session via `dbus-run-session`
3. **Your browser** connects to the KasmVNC web UI over HTTP on port 8443
4. **QGIS** is available in the applications menu and via the panel launcher

KasmVNC is driven directly (the `Xkasmvnc` binary) rather than through the `kasmvncserver` Perl wrapper, eliminating a large Perl dependency tree.

## Building from Source

### Prerequisites

- [Nix](https://nixos.org/download) with flakes enabled
- Docker

### Build

```bash
git clone https://github.com/kartoza/qgis-desktop-docker.git
cd qgis-desktop-docker

# Build the Docker image
nix build .#docker

# Load into Docker
nix store cat $(nix build .#docker --print-out-paths) | docker load

# Run
docker run --rm -p 8443:8443 nix-xfce-kasm:latest
```

### Build just the KasmVNC package

```bash
nix build .#kasmvnc
```

### Development shell

```bash
nix develop
```

### Generate build summary

```bash
bash build-summary.sh nix-xfce-kasm:latest
```

## CI/CD

### Pull Requests

Every PR triggers a build that:
- Builds the Docker image with Nix
- Uploads the image as a **7-day artifact**
- Posts a **build summary comment** on the PR with versions and SBOM

### Releases

Creating a GitHub release:
- Builds the Docker image
- Publishes to **GitHub Container Registry** (`ghcr.io/kartoza/qgis-desktop-docker`)
- Attaches the image tarball, build summary, and SBOM to the release
- Appends build details to the release notes

## Security Notes

- **No authentication** is enabled by default (`-SecurityTypes None -disableBasicAuth`). This is intended for local development use.
- For production or multi-user deployments, consider placing the container behind a reverse proxy with authentication (e.g., nginx + OAuth2 Proxy, Traefik + BasicAuth).
- The container runs as a non-root user (`user`, UID 1000).

## License

GPL-2.0 -- see [LICENSE](LICENSE) for details.

KasmVNC is licensed under GPL-2.0. QGIS is licensed under GPL-2.0.

---

Made with love by [Kartoza](https://kartoza.com) | [Donate!](https://github.com/sponsors/kartoza) | [GitHub](https://github.com/kartoza/qgis-desktop-docker)
