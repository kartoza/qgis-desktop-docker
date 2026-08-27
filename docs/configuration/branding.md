# Branding

The container serves KasmVNC's web interface, and by default that interface is
branded as KasmVNC — its tab title, its favicon, and the page a user lands on
when their session ends. For a hosted service that is the wrong name in front of
your users. This page covers what the image re-brands, what it deliberately does
not, and how to change it.

## What is branded

| Surface | What changes |
|---------|--------------|
| Entry page (`index.html`, `vnc.html`) | The `<title>`, so the browser tab reads your brand rather than "KasmVNC". |
| Favicon | The thirteen stock Kasm PNGs are replaced by a single SVG. |
| Session-ended page (`disconnected.html`) | Rendered wholesale from a template: your colours, your logo, your typeface — plus a **Sign out completely** link. |

That last one is worth dwelling on. The session-ended page is the only branded
surface that is a *real document in the user's browser*, which means it is the
only one that can clear the single sign-on cookie. The desktop cannot: it is
pixels inside a page, with no way to navigate the page containing it. So the
sign-out affordance lives here, and nowhere else.

## What is not branded, on purpose

The KasmVNC control bar and the in-session UI are **left alone**. They are a
Vite bundle (`assets/ui-*.js`) with content-hashed filenames that change on
every KasmVNC release. Patching them would turn each version bump into a
debugging session, in exchange for a toolbar most users glance at twice.

The overlay asserts every substitution it makes. If a future KasmVNC renames the
markup we key on, **the build fails** with a message naming what moved — rather
than silently producing an image that still says KasmVNC while everyone assumes
otherwise.

## Changing the brand

Every value lives in one file, `config/branding/tokens.json`:

```json
{
  "brand": { "name": "GeoSpatialHosting", "url": "https://geospatialhosting.com" },
  "color": {
    "accent": "#ECB44B",
    "accentHover": "#D9A23A",
    "secondary": "#57A0C7",
    "muted": "#888B8C",
    "surface": "#F5F5F2",
    "surfaceRaised": "#FFFFFF",
    "text": "#383939",
    "textMuted": "#676869"
  },
  "font": { "family": "Lato" }
}
```

Edit it, drop your logo at `resources/brand/`, rebuild. Colours are validated as
`#rrggbb` literals at build time, because they are interpolated straight into
CSS and a malformed one would break the stylesheet silently.

The file also carries a `_provenance` block recording which values were
confirmed from the source of truth and which are assumptions still awaiting
sign-off. Keep it honest — it is the only way anyone can tell what still needs
checking.

### Reviewing a change without building an image

The branded web root is static files, so you do not need the container:

```bash
nix run .#preview-branding
```

builds the overlay in seconds and serves it at `http://127.0.0.1:8100`. The
session-ended page is at `/disconnected.html` and is fully rendered. The entry
page is at `/index.html`; it has no desktop behind it, so it will sit at
"connecting" — its branded parts are the tab title and the favicon.

```bash
nix build .#branded-www && ls result/
```

gives you the same tree on disk to inspect.

## Turning it off

| Variable | Default | Description |
|----------|---------|-------------|
| `QGIS_DESKTOP_BRANDING` | `1` | `0` serves KasmVNC's own unmodified web root. |
| `QGIS_DESKTOP_BRANDED_WWW` | `/usr/share/qgis-desktop/www` | Where the branded root lives in the image. Point it at a bind mount to override the whole tree without rebuilding. |

!!! note "`greeter` mode ignores `QGIS_DESKTOP_BRANDING`"

    LightDM scrubs the environment before spawning the X server, so the variable
    never reaches the wrapper that starts Xkasmvnc. The fixed path is the only
    channel that survives, which is why the image copies the branded files in
    rather than symlinking them into the nix store. To serve something else in
    `greeter` mode, bind-mount over `/usr/share/qgis-desktop/www`.

## Fonts and licensing

The body typeface is bundled into the web root rather than fetched from Google
Fonts at runtime, for two reasons: the container runs under an egress allowlist
that would block the request, and the session-ended page is by definition
reached when things have gone wrong — it must not depend on the network.

Bundling means redistributing, so the typeface must be licensed for it. **Lato**
is SIL OFL and safe. If your brand's display face is a commercial licence —
Avenir, Gotham, Proxima Nova and friends — **do not put it in the image**. Use
it on your website and pick an open face for the container.


---

Made with love by [Kartoza](https://kartoza.com) —
[Donate!](https://github.com/sponsors/kartoza) —
[GitHub](https://github.com/kartoza/qgis-desktop-docker).
