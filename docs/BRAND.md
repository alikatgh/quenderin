# Quenderin brand & anti-slop guide

Written 2026-07-03, after the owner's verdict on the previous design: *"total AI-slop."*
The diagnosis and the plan below drove the redesign shipped that day (commits `caecb4f`,
`9b109fb`). This is the living reference for future design work — check new UI, pages,
and copy against it before shipping.

## The diagnosis

The individual pieces were competently executed, but the *choices* were all median
choices — and that's what reads as AI-slop. **Slop isn't sloppiness; it's the absence of
decisions only we would make.** The test: remove the elf and the word "Quenderin" — if
what remains could be any of fifty local-LLM projects, it's slop.

### The tells (banned — check every new page/screen against this list)

- **Template genetics.** The old palette was literally Stripe's `#635BFF` on the
  Stripe-pattern hero (animated blob gradient, eyebrow → huge headline → lede → CTA pair
  → spec strip). Every AI-generated landing page converges on exactly this because it's
  the median of the training data. Banned: purple `#635BFF`/`#8B83FF`, animated/mesh
  gradient backgrounds, bento-for-bento's-sake.
- **AI cadence in copy.** "Offline · Private · Yours." "Download once. Run forever."
  "No internet, no API keys, no telemetry." Triplets, mirrored aphorisms, zero risk.
  No human wrote those sentences angry or excited. Banned: rule-of-three slogans,
  "forever", mirrored aphorisms, unmeasured superlatives.
- **Uniform glossiness, zero specificity.** No dates, no device names, no measured
  numbers, no admitted trade-offs, no opinions. Uniform polish is the texture of
  generated work. Required instead: at least one real number with a source, per page.
- **Fake product imagery.** Hand-built CSS mockups of the app drift from the product and
  read as generated. Product images are RENDERED FROM THE REAL UI via
  `WebsiteAssetRenderTests` (`QUENDERIN_RENDER_ASSETS=<dir> swift test --filter
  WebsiteAssetRender`) — regenerate when the UI changes.

## The three genuine assets (nobody can fake these — lean on them)

1. **The elf.** Distinctive, slightly weird, memorable — and the name *Quenderin* is
   straight out of Tolkien's *Quendi*, "the speakers." An AI that *speaks*, living
   quietly in your pocket, off the grid. The artwork carries motifs (the Tengwar-style
   script on her face, the knotwork on the choker) usable as dividers, borders, loading
   states. No template has those.
2. **Our honesty.** `apple/REALITY.md` says "~3.8 tok/s on an S23 before tuning" and
   "treat these columns as estimates"; the app ships a model graded quality **Low**. No
   marketing site admits that — which is exactly why publishing it is instantly,
   recognizably human. Claims are slop; evidence is genuine. (Shipped as
   `website/reality.html` — keep it current.)
3. **The voice we already write in privately.** Commit messages and docs here have
   opinions ("a hash you can't copy is decoration"). Public copy should sound like that:
   *"It's a 1B model. It will sometimes be confidently wrong. It will also answer you
   three days into a hike."* First person, specific, trade-offs included.

## The plan, and where it stands

| # | Change | Status |
|---|--------|--------|
| 1 | **Palette derived from the elf artwork, not Stripe** — teal braids `#52939A`/`#2E7680`, copper pendant `#EDA04F`/`#C46B2C`, gold engraving `#F7C259`, warm paper, teal-ink. Token sources: `apple/.../Theme.swift`, `android/.../ui/Theme.kt`, `website/styles.css :root`, documented in `docs/DESIGN_SYSTEM.md`. If the art changes, RESAMPLE (PIL hue-band sampling) — don't guess. | ✅ shipped `9b109fb` |
| 2 | **Kill the blob-gradient hero** — still teal-ink + two quiet glows, real screenshot, restraint over spectacle. Removed site-wide. | ✅ shipped `9b109fb` |
| 3 | **Copy in dev-log voice** — measured numbers ("~15 tok/s on an iPhone 12, measured"), first person, admitted limits. English done; **the 11 non-EN translations still carry the old copy** (i18n keys override the new English). | 🟡 EN done; retranslation open |
| 4 | **Publish the homework** — `website/reality.html`: measured decode table (interpolations labeled), the honesty list, links to REALITY.md / research / bug journal. | ✅ shipped `9b109fb` |
| 5 | **Typography with a point of view** — Bricolage Grotesque (self-hosted, OFL) already carries headlines. Still open: the artwork motifs (facial script, knotwork) as section dividers / borders / a loading state; consider a storybook-leaning display refinement. | 🟡 partly; motifs unexplored |

## Still open (future work)

- Retranslate the rewritten strings for the 11 non-English locales (`website/i18n/*.json`).
- Extract the engraving/knotwork motifs from `brand/icon-source.png` into SVG accents
  (section dividers, empty states, a loading spinner with the choker knot).
- Sweep the marketing subpages (`features.html`, `how-it-works.html`, `models.html`,
  `faq.html`) for leftover AI-cadence copy — the token/palette cascade already restyled
  them, but the words haven't had the voice pass.
- The elf could earn a name and a one-paragraph lore note (Quendi, "the speakers") on an
  about page — quiet, not cosplay.
- OG image (`og-image.png`) still shows the old branding — regenerate from the new
  identity.
