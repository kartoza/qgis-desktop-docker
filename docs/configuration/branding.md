# Branding

The container serves KasmVNC's web interface, and by default that interface is
branded as KasmVNC — its tab title, its favicon, and the page a user lands on
when their session ends. For a hosted service that is the wrong name in front of
your users. This page covers what the image re-brands, what it deliberately does
not, and how to change it.

## What is branded

| Surface | What changes |
|---------|--------------|
| Browser tab | The `<title>`, so it reads your brand rather than "KasmVNC". |
| Favicon | The thirteen stock Kasm PNGs collapse to a single SVG. |
| Control bar | The panel down the left of the screen. Its header carried Kasm's logo as an inline `data:` URI, linked to kasmweb.com; both become yours. |
| Connection-error message | Said "KasmVNC encountered an error:" — the string a user is most likely to read, because they only see it when something has already gone wrong. |
| Keyboard-shortcuts toggle | "Enable KasmVNC Keyboard Shortcuts" in the settings panel. |
| Session-ended page | Rendered wholesale from a template: your colours, logo and typeface, plus a **Sign out completely** link. |

All of the above lives in the entry page's own **HTML**, which is what makes it
safe to rewrite.

The session-ended page is worth dwelling on. It is the only branded surface that
is a *real document in the user's browser*, which means it is the only one that
can clear the single sign-on cookie. The desktop cannot: it is pixels inside a
page, with no way to navigate the page containing it. So the sign-out affordance
lives there, and nowhere else. KasmVNC redirects to it on disconnect, so it is
genuinely on the path users take.

## The wallpaper, and the gap on log-out

It deliberately uses the same visual language as the session-ended page — the
same light surface, the same Lato, the same amber accent rule — so that someone
who logs out and back in feels they stayed inside one product.

The wallpaper is rendered from `config/branding/wallpaper.svg.in` at
build time, with its colours coming from the same tokens file. Edit the SVG or
the tokens and rebuild; `nix build .#branded-wallpaper` renders it in about a
second so you can look at a change without an image build.

It shows up in three places, which is why it is worth getting right:

- the XFCE desktop;
- the LightDM greeter background in `greeter` mode;
- the X root window.

That last one is the fix for a real complaint. `xfdesktop` draws the wallpaper,
but it dies with the session — so between XFCE exiting on **Log Out** and the
supervisor restarting it, users were left looking at the bare X root window for
several seconds. Flat blue, no explanation, easily mistaken for a fault.
`start-desktop.sh` now paints the root window once, as soon as X is up: a solid
brand colour first, then the wallpaper over it. The root window outlives every
session restart, so painting it once covers the gap for the life of the
container, and `xfdesktop` simply draws over it while a session runs.

| Variable | Default | Description |
|----------|---------|-------------|
| `QGIS_DESKTOP_WALLPAPER` | `/usr/share/wallpaper.png` | The image painted on the root window and used by the greeter. Bind-mount over it to change the wallpaper without rebuilding. |
| `QGIS_DESKTOP_ROOT_COLOR` | `#0D161C` | Solid colour painted first, and the fallback if the image cannot be drawn. |

### What applies in which mode

The branding is served by both desktop paths, so it is the same everywhere. The
log-out handling deliberately is not.

| | `basic` / `none` | `oidc` | `greeter` |
|---|---|---|---|
| Branded web UI | yes | yes | yes |
| Branded wallpaper | yes | yes | yes, as the greeter background |
| Session restarts on log out | yes | yes (inner mode `none`) | **no — LightDM re-shows its login form instead**, which is the better behaviour where real per-user accounts exist |
| Root window painted | yes | yes | not needed: the greeter fills the screen itself |

`bash claude.sh verify` exercises `basic`, `none` and `greeter` against a built
image and asserts exactly that table. `oidc` needs a live identity provider, so
it stays a manual check via `nix run .#run-keycloak-demo` — its desktop path is
whichever inner mode is configured, and both of those are already covered.

## Linking back to your control panel

When you give it a URL, a button pointing there appears on the session-ended
page. There is no control-bar equivalent — the control bar carries no branding
at all (see [What is not branded, on purpose](#what-is-not-branded-on-purpose)).
Unset, nothing is shown.

```bash
docker run ... \
  -e QGIS_DESKTOP_MANAGE_URL=https://geospatialhosting.com/dashboard \
  -e QGIS_DESKTOP_MANAGE_LABEL="Manage my desktops" \
  ghcr.io/kartoza/qgis-desktop-docker:ltr
```

| Variable | Default | Description |
|----------|---------|-------------|
| `QGIS_DESKTOP_MANAGE_URL` | *(none)* | Where the management link points — your control panel, per deployment. Unset, nothing is shown. |
| `QGIS_DESKTOP_MANAGE_LABEL` | `Manage my desktops` | Button text. |

Only `http://` and `https://` are accepted; anything else is refused with a
warning in the container log and nothing is shown, rather than emitting a link
that does not work or, worse, a `javascript:` URL.

### Why this happens at container start

The URL belongs to the deployment, not to the image — one image serves many
customers, each needing a link to their own control panel — so it cannot be
baked in at build time. The build therefore ships two files for each page it
touches: a template carrying a marker, and a rendered page that is valid on its
own. `qgis-desktop-manage-link` runs as root at boot and re-renders the second
from the first.

Rendering from a pristine template rather than editing in place is what makes it
idempotent: a container restart cannot end up with the notice inserted twice.

## What is not branded, on purpose

**The control bar down the left of the screen** carries no logo or link at
all — the header KasmVNC puts there is stripped outright rather than replaced
with a brand logo.

Two more things are left alone.

**The Vite bundle** (`assets/ui-*.js`) and the content-hashed stylesheets are
byte-identical to upstream, and a test asserts it. Their filenames change on
every KasmVNC release; patching them would turn each version bump into a
debugging session.

**The Settings → Documentation link** still points at KasmVNC's own docs,
because those docs genuinely describe these very controls — an outbound link
that helps beats one of ours that 404s. Set `brand.docsUrl` in the tokens file
to redirect it at your own help.

The overlay asserts every substitution it makes. If a future KasmVNC renames the
markup we key on, **the build fails** with a message naming what moved — rather
than silently producing an image that still says KasmVNC while everyone assumes
otherwise. Nine of the tests exist only to prove that.

## Changing the brand

Every value lives in one file, `config/branding/tokens.json`:

```json
{
  "brand": {
    "name": "GeoSpatialHosting",
    "url": "https://geospatialhosting.com"
  },
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
