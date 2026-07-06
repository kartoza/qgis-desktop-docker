# Quick start

Pull the pre-built image from GitHub Container Registry, run it, and log in.

## Pull and run

```bash
docker pull ghcr.io/kartoza/qgis-desktop-docker:latest
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

Open <http://localhost:8443> and log in with the built-in credentials
**`user`** / **`password`**. The browser will show its native HTTP BasicAuth
dialog; those credentials are reused transparently for the VNC handshake so
you only see one prompt.

!!! warning "NET_ADMIN is required"
    The container starts an nftables egress firewall as its first act. It
    needs `--cap-add=NET_ADMIN` to install the rules. Without it, and with
    the default `KASM_EGRESS_LOCKDOWN=1`, the container **fails closed**
    and exits with a diagnostic. If you deliberately want unrestricted
    networking, set `-e KASM_EGRESS_LOCKDOWN=0` — but only for local dev.

## Using Docker Compose

Grab the sample compose file and start:

```bash
curl -O https://raw.githubusercontent.com/kartoza/qgis-desktop-docker/main/docker-compose.yml
docker compose up -d
```

The stock compose file mounts a named `qgis-home` volume so QGIS settings,
plugins, and projects survive container restarts:

```yaml
services:
  qgis-desktop:
    image: ghcr.io/kartoza/qgis-desktop-docker:latest
    cap_add:
      - NET_ADMIN
    ports:
      - "8443:8443"
    environment:
      - VNC_RESOLUTION=1920x1080
    volumes:
      - qgis-home:/home/user
    restart: unless-stopped

volumes:
  qgis-home:
```

## Change the defaults

Common overrides via `-e`:

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -e VNC_RESOLUTION=1920x1080 \
  -e KASM_USERS='alice:pw1,bob:pw2' \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

For the full matrix of knobs, see [Configuration](../configuration/index.md).

!!! tip "Private GHCR package?"
    If the package is private, authenticate first:
    `echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin`.
