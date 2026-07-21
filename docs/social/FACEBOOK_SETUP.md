# Facebook — status + remaining steps

**Page:** facebook.com/quenderin (bio already set: "Local LLMs that run inside
your phone").

## What's built (code side — done)

- **Strategy:** `docs/FACEBOOK_STRATEGY.md` — positioning, voice, pillars, cadence.
- **Content:** `scripts/social-content.cjs` — 44 bespoke posts across 3 pillars.
- **Calendar:** `docs/social/calendar.{json,md}` — 68 posts, Mon/Wed/Fri, **2026-07-27
  → 2026-12-31**. Unique through ~26 Oct; the Nov–Dec tail rotates the pool
  (marked ↻ — refresh those angles nearer the date). Regenerate any time:
  `node scripts/gen-social-posts.cjs --start 2026-07-27 --end 2026-12-31`.
- **Poster:** `scripts/post-to-facebook.cjs` — posts the entry whose date == today,
  screenshot + caption, link in the first comment. No-ops safely without a token.
- **Cron:** `.github/workflows/social-post.yml` — 14:00 UTC Mon/Wed/Fri, dormant
  until the two secrets exist.
- **Assets:** every post image is already public at `quenderin.org/assets/app/…`;
  the cover graphic is at `quenderin.org/assets/social/feature-graphic-1024x500.png`.

## Delivery model (hybrid — same as before)

- **Weeks 1–2 (Mon 07-27 → Fri 08-07, 6 posts): hand-scheduled by you** in the
  Meta Business Suite Planner. These fire via Facebook's own scheduler — no token
  needed. Captions + image URLs are in `docs/social/calendar.md`.
- **Week 3 onward (from Mon 08-10): the cron** posts automatically, once the token
  is added. `FB_AUTOPILOT_FROM=2026-08-10` in the workflow makes the cron skip
  everything before that day, so the hand-scheduled window can't double-post.

## Your steps

### 1. Page cosmetics (~5 min)
- **Profile picture:** the Quenderin brand mark (teal/copper) — replace the grey
  "Q" placeholder.
- **Cover:** upload `website/assets/social/feature-graphic-1024x500.png` (or the
  3D-phone hero).
- **About → Website:** `https://quenderin.org`; add the App Store link
  `https://apps.apple.com/app/id6789854363`.

### 2. Hand-schedule weeks 1–2 (~15 min)
In Meta Business Suite → **Planner** → Create post → Schedule, for each of the 6
dates below (14:00 in your timezone is fine). Copy the caption + image from
`docs/social/calendar.md`; after each publishes, **add the link as the first
comment** yourself (the cron does this automatically later):

| Date | Pillar | Post |
|------|--------|------|
| Mon 07-27 | spotlight | ios-launch |
| Wed 07-29 | engineering | ggml-abort |
| Fri 07-31 | reality | sometimes-wrong |
| Mon 08-03 | spotlight | offline-proof |
| Wed 08-05 | engineering | model-integrity |
| Fri 08-07 | reality | real-numbers |

### 3. Mint the token + add secrets — **before Mon 08-10** (~10 min)
1. **developers.facebook.com** → My Apps → **Create App** → type **Business**
   (name e.g. `quenderin-poster`; it can stay in Dev mode — you're only posting
   to your own Page).
2. **Graph API Explorer** → select the app → **Get Page Access Token** → pick the
   Quenderin Page → approve `pages_manage_posts` + `pages_read_engagement`.
3. Exchange for a long-lived token: GET
   `oauth/access_token?grant_type=fb_exchange_token&client_id=<APP_ID>&client_secret=<APP_SECRET>&fb_exchange_token=<SHORT_TOKEN>`
   (App ID/Secret: app → Settings → Basic). Then with that long-lived **user**
   token, GET `me/accounts` — the response lists the Page's **`id`** (= FB_PAGE_ID)
   and an **`access_token`** (= FB_PAGE_TOKEN; a Page token from a long-lived user
   token does not expire).
4. github.com/alikatgh/quenderin → Settings → Secrets and variables → Actions →
   New repository secret, twice:
   - `FB_PAGE_ID` — the numeric Page id
   - `FB_PAGE_TOKEN` — the Page access token

### 4. Test, then it's automatic (~2 min)
- GitHub → **Actions → "Quenderin → Facebook" → Run workflow** with
  `dry_run = true` → confirm it prints the right post.
- Run again with `dry_run = false` and `date = 2026-08-10` to publish the first
  cron post live. If it looks right, you're done — every Mon/Wed/Fri fires
  automatically through December.

## Ongoing (~15 min/week — see FACEBOOK_STRATEGY.md)
- Reply to comments; end reality posts by inviting one ("what model next?").
- Share the spotlight + engineering posts into 8–10 relevant Groups (local-LLM,
  self-hosted-AI, privacy, Apple-silicon-ML, open-source-AI), respecting rules.
- After 2 weeks, boost the best organic performer ($10, interest: AI/privacy/OSS).
- For the beta window, screenshot "when Android public?" / "add model X" comments —
  that's the demand evidence.

## Token expiry
If posting ever fails with an OAuth error, re-run step 3.2–3.3 and update the
`FB_PAGE_TOKEN` secret. The workflow fails loudly in the Actions tab.

## Open decision — Russian stream
First users are Russian-speaking and the site ships `ru`. The generator is
English-only today but structured to add a `ru` stream (a parallel calendar,
geo-targeted) the way the plan describes. Say the word and it's a fast-follow.
