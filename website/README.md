# Quenderin marketing website

A static marketing site with a landing page, downloads, blog, changelog, and support pages. **No build step or third-party runtime requests.** HTML, CSS, vanilla JS, and a self-hosted font.

```
website/
├── index.html          # the landing page
├── styles.css          # design system + all sections
├── main.js             # mobile nav, scroll reveal, theme toggle, footer year
├── gradient.js         # Stripe-style WebGL mesh gradient (reduced-motion aware)
├── favicon.svg         # brand mark (modern browsers)
├── favicon-16/32.png   # PNG favicon fallbacks  ┐
├── apple-touch-icon.png# iOS home-screen icon   ├─ generated, see scripts/rasterize.mjs
├── og-image.svg/.png   # social share card 1200×630 (PNG is what scrapers read) ┘
├── site.webmanifest    # PWA manifest (installable, theme color)
├── 404.html            # off-grid 404
├── robots.txt
├── sitemap.xml
├── netlify.toml        # Netlify config
├── vercel.json         # Vercel config
└── scripts/
    ├── serve.py        # sandbox-safe static server (absolute paths; no os.getcwd)
    ├── shoot.mjs       # full-page / per-section screenshots via Chrome DevTools
    └── rasterize.mjs   # SVG → PNG for og-image + favicons + apple-touch-icon
```

## Regenerate the PNG assets

The favicons, `apple-touch-icon.png`, and `og-image.png` are **generated** from the
SVGs — edit `favicon.svg` / `og-image.svg`, then re-run (requires Google Chrome):

```bash
node website/scripts/rasterize.mjs   # → og-image.png, favicon-16/32.png, apple-touch-icon.png
```

To screenshot the rendered site (full page + every section, light/dark, any width):

```bash
python3 website/scripts/serve.py 8099 &                 # static server
node website/scripts/shoot.mjs http://127.0.0.1:8099/ /tmp/shots dark 1440
```

## Preview locally

Any static server works — no build:

```bash
cd website
python3 -m http.server 8080
# open http://localhost:8080
```

## Apple launch materials

- Primary launch story: `blog-apple-launch.html` (30 September 2026).
- Both Apple apps use the same listing: `https://apps.apple.com/app/id6789854363`.
  Use `?platform=mac` or `?platform=iphone` to send visitors to the right platform.
- App icons in `assets/app/icon-ios.png` and `icon-mac.png` are exported at 320 px from the native
  asset catalog, not independently designed website substitutes.
- Platform glyphs in `icons/` identify the download choices. Keep the official
  App Store badge unchanged.
- Landing-page launch and setup copy is localized in all 12 `i18n/*.json` files.
  Keep English dictionary values aligned with the first-paint HTML.
- `og-image.svg` and `og-image.png` are the share card; the SVG embeds the actual
  app icon. The 192/512 PNG icons cover the website manifest.
- Social captions and release wording are in `docs/APPLE_LAUNCH_MATERIALS.md`.

## Publish the website

The production domain **quenderin.org** is served by the assets-only Cloudflare
Worker configured in `wrangler.site.jsonc`. The GitHub workflow also maintains
GitHub Pages and the Cloudflare Pages preview when its configured secret is present.

```bash
npx wrangler deploy --config wrangler.site.jsonc
```

`bash scripts/deploy_website.sh` triggers all configured targets, but its GitHub
workflow publishes the remote default branch. Push the intended website changes
before using that part of the script. A local preview or pushed task branch is
not production deployment evidence; check the live launch story and download links.

## Editing

All copy lives in `index.html`; all styling in `styles.css` (CSS variables at the
top control the palette). The design follows the project rule set: hairline
borders (no shadows), interactive states change color only (never geometry),
hierarchy via weight + size, tabular numbers, monospace for specs.
