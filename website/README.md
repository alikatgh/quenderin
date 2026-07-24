# Quenderin marketing website

A single-page, static marketing site. **No build step, no dependencies, no
external requests** (system fonts only) — fitting for a privacy product. Just
HTML, CSS, and a few lines of vanilla JS.

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

## Put it online — pick one

### A. Cloudflare Pages (recommended)
Create a Pages project → connect this repo → set **Build output directory** to
`website` and leave the build command empty (the site is static). `website/_headers`
applies the security headers. Add your custom domain under the project's
*Custom domains* tab.

### B. Netlify
New site → connect the repo → set **Base directory** to `website`. `netlify.toml`
handles the rest. (Or drag-and-drop the `website/` folder into Netlify.)

### C. Vercel
Import the repo → set **Root Directory** to `website`. `vercel.json` handles the rest.

### D. GitHub Pages (dormant)
A ready-made workflow sits at **`website/deploy/github-pages.yml`**, deactivated.
To enable it: `git mv website/deploy/github-pages.yml .github/workflows/deploy-website.yml`,
push, then set repo **Settings → Pages → Source: GitHub Actions**.

## Configure before launch

- **Custom domain** — update the `canonical`, Open Graph `og:url` / `og:image`, the
  JSON-LD `url`, and `sitemap.xml` / `robots.txt` from `alikatgh.github.io/quenderin`
  to your domain (e.g. across `index.html` + the legal pages).
- **Social image** — `og-image.png` (1200×630) is already generated and wired into the
  `og:image` / `twitter:image` tags. Re-run `node scripts/rasterize.mjs` after editing
  `og-image.svg`.
- **Following the project** — the CTA is GitHub-only (Star + Watch releases); there is no
  email form or third-party dependency to configure.

## Editing

All copy lives in `index.html`; all styling in `styles.css` (CSS variables at the
top control the palette). The design follows the project rule set: hairline
borders (no shadows), interactive states change color only (never geometry),
hierarchy via weight + size, tabular numbers, monospace for specs.
