# website/ audit — 2026-07-11

**Scope:** the marketing/docs site that landed on main 2026-07-10 (`website/` +
`wrangler.site.jsonc`) — a surface no round of the 50-round plan ever covered.
**Method:** scripted link/asset/meta/sitemap/SW checks over all 21 pages + live preview.

## Findings

### W1 — sitemap.xml was missing 11 of 20 indexable pages — **FIXED** (Medium, SEO)
- Absent: the whole blog (index + 3 posts), `download`, `changelog`, `help`, `reality`,
  `research`, `roadmap`, `why-local-agent` — i.e. most of the newer content, including the
  page conversions care about most (`download`). Regenerated with all 20 pages, priorities
  consistent with the existing scheme (404 excluded).

### W2 — the `website` preview launch config was broken on this machine — **FIXED** (tooling)
- Xcode's python3 dies with a sandbox `PermissionError` under the preview harness. Replaced
  with a dependency-free node static server (`scripts/serve_website.mjs`, traversal-guarded,
  404-page-aware) and pointed `.claude/launch.json` at it.

## Verified good (no action)
- **All 21 pages**: `<title>` + meta description present (404 conventionally exempt); zero
  broken internal links; zero missing assets; all sitemap URLs resolve; SW precache list
  references only existing files.
- **Headers posture** (`_headers`): nosniff, no-referrer, DENY framing, tight CSP,
  `sw.js` no-cache (a pinned stale service worker can't hold the origin hostage — commented
  inline). Netlify/Vercel configs mirror it; Cloudflare Pages honors `_headers` natively.
- **Live**: homepage renders with zero console errors; i18n selector + theme toggle present;
  key pages (download/blog/roadmap/reality/research/models/faq/help/changelog) all 200 with
  correct titles.

## Open
- None. (If the blog grows, consider generating sitemap.xml the way FEATURES.md's table is
  generated — same drift class as W1.)
