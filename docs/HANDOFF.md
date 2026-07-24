# Handoff — pick up here

_Last updated: 2026-07-21. Read this first when resuming on another machine._
_(Agent memory lives in `~/.claude/…` and does NOT travel between machines — this
file is the source of truth for cross-machine context.)_

## TL;DR — what's left to do (in priority order)

1. **🔑 Mint `FB_PAGE_TOKEN` before Mon 2026-07-27.** This is the single lever that
   starts the Facebook auto-posting. Runbook: [`docs/social/FACEBOOK_SETUP.md`](social/FACEBOOK_SETUP.md)
   §2. Add `FB_PAGE_ID` + `FB_PAGE_TOKEN` as repo secrets → the 68-post calendar
   posts itself Mon/Wed/Fri through December. Nothing else needed.
2. **🖼️ Upload the FB page cover + profile image** (manual — FB uses a native OS
   file picker that browser automation can't drive). Files are ready:
   - Cover → `website/assets/social/feature-graphic-1024x500.png`
   - Profile → `brand/icon-square-1024.png` (the elf-art brand mark)
3. **Review branch `wip/website-deploy-docs`** (see Gotchas) — preserved old WIP;
   decide whether to keep, reconcile, or delete it.
4. **Later:** refresh the ↻-rotated Nov–Dec social posts; finish the RU Play
   screenshots; optionally add a Russian social stream.

Everything code-side is committed, pushed to `origin/main`, and deployed. Working
tree is clean.

---

## What shipped this session (all on `main`, all deployed)

| SHA | What |
|-----|------|
| `20ac688` | Social: full-auto delivery (cron covers whole calendar from launch) |
| `d0f9563` | **Facebook content machine** — strategy, calendar, poster, cron |
| `37c3779` | Play closed-beta submission assets |
| `35da4e5` | Killed stale "Android on the way" copy |
| `d98cb5a` | Android closed-beta homepage section + blog post |
| `c8a62f6` | Tighter hero + a phone that actually reads 3D |
| `28b3b15` | Plainer section headings |

Website is live at **quenderin.org**. iOS is live on the App Store
(`id6789854363`). Android is in **closed beta** (see links below).

---

## The Facebook content machine (the big new thing)

Mirrors the `ottor_mastar` playbook (that repo is the reference implementation).
Pipeline: **strategy → generator → calendar → poster → cron.**

| File | Role |
|------|------|
| [`docs/FACEBOOK_STRATEGY.md`](FACEBOOK_STRATEGY.md) | positioning, voice, 3 pillars, cadence |
| [`scripts/social-content.cjs`](../scripts/social-content.cjs) | 44 bespoke posts (edit here to change content) |
| [`scripts/gen-social-posts.cjs`](../scripts/gen-social-posts.cjs) | schedules them → `docs/social/calendar.{json,md}` |
| [`scripts/post-to-facebook.cjs`](../scripts/post-to-facebook.cjs) | Graph-API poster (photo + caption, link in 1st comment) |
| [`.github/workflows/social-post.yml`](../.github/workflows/social-post.yml) | cron 14:00 UTC Mon/Wed/Fri |
| [`docs/social/calendar.md`](social/calendar.md) | the human-readable 68-post calendar |
| [`docs/social/FACEBOOK_SETUP.md`](social/FACEBOOK_SETUP.md) | owner runbook (token, etc.) |

- **Regenerate the calendar:** `node scripts/gen-social-posts.cjs --start 2026-07-27 --end 2026-12-31`
- **Dry-run the poster:** `node scripts/post-to-facebook.cjs --date 2026-07-27 --dry-run`
- **Schedule:** 68 posts, Mon/Wed/Fri, **2026-07-27 → 2026-12-31**. Pillars:
  Mon = model/feature spotlight · Wed = behind-the-engineering · Fri = honest
  reality/privacy/community. Unique through ~26 Oct; Nov–Dec entries are marked
  **↻ rotated** in `calendar.md` (they reuse the pool — refresh their angle
  before they publish).
- **Full-auto config:** `FB_AUTOPILOT_FROM=2026-07-27` in the workflow → the cron
  posts the whole calendar once the token exists. No hand-scheduling. Poster
  no-ops safely without the token.
- **Post images** are already public at `quenderin.org/assets/app/*.png`.
- **Decision made:** social posts are **English-only** for now. The generator is
  structured to add a Russian stream later (fast-follow), but it's shelved.

### The one blocker: the FB Page token (owner-only)
`developers.facebook.com` → create Business app → Graph API Explorer → Get Page
Access Token (`pages_manage_posts`, `pages_read_engagement`) → exchange for
long-lived → `GET me/accounts` for the Page `id` + `access_token`. Add both as
`FB_PAGE_ID` / `FB_PAGE_TOKEN` under repo Settings → Secrets → Actions. Full steps
in `FACEBOOK_SETUP.md` §2.

---

## Facebook Page manual state (facebook.com/quenderin, admin = Albert)

Done this session (via browser, saved & verified):
- **About → Links** (4, live): Website `quenderin.org` · App Store
  `apps.apple.com/app/id6789854363` · Android beta `groups.google.com/g/quenderin-testers`
  · GitHub `github.com/alikatgh/quenderin`.
- **Bio** ("Local LLMs that run inside your phone") and **category** (Science,
  Technology & Engineering) were already set.

Still to do (manual — native file picker blocks automation):
- **Cover photo** ← `website/assets/social/feature-graphic-1024x500.png`
- **Profile picture** ← `brand/icon-square-1024.png`

---

## Deploy (website) — how quenderin.org is served

Primary = a Cloudflare **Worker** named `quenderin` (account `wallmarketshq`),
NOT Pages. After editing `website/`:

```bash
npx wrangler deploy --config wrangler.site.jsonc                          # → quenderin.org (primary)
npx wrangler pages deploy website --project-name=quenderin --commit-dirty=true   # Pages mirror
gh workflow run "Deploy website"                                         # GH Pages (also auto on push)
```

---

## Key references

- **App Store (iOS, live):** https://apps.apple.com/app/id6789854363
- **Android package:** `ai.quenderin.app` · beta group
  https://groups.google.com/g/quenderin-testers · opt-in
  https://play.google.com/apps/testing/ai.quenderin.app
- **Repo:** github.com/alikatgh/quenderin · **Site:** https://quenderin.org
- **FB page:** facebook.com/quenderin · **Social reference impl:** `../ottor_mastar`

## Open follow-ups / decisions

- Refresh the **↻-rotated Nov–Dec** social posts (see `calendar.md`).
- **`appstore/play/screenshots/phone-ru-play/`** has only 2 of 5 screens — RU Play
  listing is incomplete (first users are Russian-speaking).
- Optional: a **Russian social stream** (deferred; English-only for now).
- Optional: FB Page primary action button (not set — header didn't expose it).

## Gotchas / environment

- **Branch `wip/website-deploy-docs`** (pushed): the old local stash, preserved so
  nothing was lost across machines. It's only the `website/README.md` deploy-docs
  rewrite (Cloudflare-first); the stash also meant to delete
  `.github/workflows/deploy-website.yml` but that's **stale** — main now uses the
  Cloudflare Worker + Pages mirror + GH Pages. **Not merged.** Reconcile with
  main's current deploy story before merging, or just delete the branch. Based on
  old commit `28fe0a4`, not current main.
- **Signing secret is safe:** `android/keystore.properties` (real store/key
  passwords) is gitignored on main. It briefly got swept into the wip commit while
  branching off the old base (which predated the ignore rule) — caught and stripped
  before any push, so it never left this machine. Don't `git add -A` on a branch
  based on pre-`android/.gitignore` history.
- **Browser automation** (claude-in-chrome) was flaky this session; **FB image
  upload is blocked** by the native OS file picker — those two uploads are
  inherently manual.
- Memory files (`~/.claude/projects/.../memory/`) are **machine-local** and won't
  be on the other machine — this doc carries the context instead.
