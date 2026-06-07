# Quenderin marketing website

A single-page, static marketing site. **No build step, no dependencies, no
external requests** (system fonts only) — fitting for a privacy product. Just
HTML, CSS, and a few lines of vanilla JS.

```
website/
├── index.html      # the landing page
├── styles.css      # design system + all sections
├── main.js         # mobile nav, scroll reveal, footer year
├── favicon.svg     # brand mark
├── og-image.svg    # social share card (1200×630)
├── 404.html        # off-grid 404
├── robots.txt
├── sitemap.xml
├── netlify.toml    # Netlify config
└── vercel.json     # Vercel config
```

## Preview locally

Any static server works — no build:

```bash
cd website
python3 -m http.server 8080
# open http://localhost:8080
```

## Put it online — pick one

### A. GitHub Pages (recommended)
A ready-made workflow ships at **`website/deploy/github-pages.yml`**. It lives
here rather than in `.github/workflows/` only because the token that pushed this
commit lacked GitHub's `workflow` scope — so activate it from your own machine or
the web UI (both have the scope):

1. Put it in place — either:
   - **Web UI:** GitHub → *Add file → Create new file* → name it
     `.github/workflows/deploy-website.yml`, paste the contents of
     `website/deploy/github-pages.yml`; or
   - **Locally:** `git mv website/deploy/github-pages.yml .github/workflows/deploy-website.yml`
     then commit & push (your local credentials have `workflow` scope).
2. Repo **Settings → Pages → Source: GitHub Actions** (one-time).
3. Done — every push touching `website/` publishes to `https://alikatgh.github.io/quenderin/`.

### B. Netlify
New site → connect the repo → set **Base directory** to `website`. `netlify.toml`
handles the rest. (Or drag-and-drop the `website/` folder into Netlify.)

### C. Vercel
Import the repo → set **Root Directory** to `website`. `vercel.json` handles the rest.

## Configure before launch

- **Waitlist form** — `index.html` has a `<form action="https://formspree.io/f/your-form-id">`.
  Replace that endpoint with your own [Formspree](https://formspree.io) (or other)
  form ID. The "Star on GitHub" CTA works without any setup.
- **Custom domain** — update the `canonical`, Open Graph `og:url`/`og:image`, and
  `sitemap.xml`/`robots.txt` URLs from `alikatgh.github.io/quenderin` to your domain.
- **OG image** — `og-image.svg` works on most platforms; some social scrapers
  prefer PNG. If a preview doesn't render, rasterize it to `og-image.png` (1200×630)
  and update the two `og:image` / `twitter:image` tags.

## Editing

All copy lives in `index.html`; all styling in `styles.css` (CSS variables at the
top control the palette). The design follows the project rule set: hairline
borders (no shadows), interactive states change color only (never geometry),
hierarchy via weight + size, tabular numbers, monospace for specs.
