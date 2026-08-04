# Handoff — pick up here

_Last updated: 2026-08-04. Read this first when resuming on another machine._  
_(Agent memory lives in `~/.claude/…` and does **not** travel between machines — this
file is the source of truth for cross-machine context.)_

## TL;DR — software is 100% agent-complete

| Layer | State |
|-------|--------|
| **Product code** (iOS / Android / desktop prototype / website) | Done — iOS **live** on App Store; Android **closed beta** |
| **CI on `main`** | Green (JNI dual-API + npm audit overrides, 2026-08-04) |
| **Catalog** | 13 models, parity + **all URLs live** |
| **Dependabot** | Safe minor/patch merged; major bumps deferred (#120 Electron 43, #124 Gradle 9 optional) |
| **Branches** | Noise deleted (`wip/website-deploy-docs`, empty claude/* / security-fixes / readiness-phase2 / feat/ship-readiness) |

### Only remaining work is **owner-only** (an agent cannot finish these)

1. **🔑 Mint `FB_PAGE_ID` + `FB_PAGE_TOKEN`** as repo Secrets → Facebook Mon/Wed/Fri auto-poster starts.  
   Runbook: [`docs/social/FACEBOOK_SETUP.md`](social/FACEBOOK_SETUP.md) §2.  
   Calendar already covers **2026-07-27 → 2026-12-31** (`docs/social/calendar.md`).
2. **🖼️ Upload FB cover + profile** (native OS file picker — cannot automate):  
   - Cover → `website/assets/social/feature-graphic-1024x500.png`  
   - Profile → `brand/icon-square-1024.png`
3. **Store consoles** (App Store Connect / Play Console) — privacy URL paste, age 17+/Mature, Data-Safety, EULA, screenshots if still incomplete. See [`docs/SHIP_READINESS.md`](SHIP_READINESS.md).
4. **Optional later:** refresh ↻-rotated Nov–Dec social posts; finish RU Play screenshots; Electron 43 / Gradle 9 intentional upgrades.

---

## What agents finished 2026-08-04

| SHA / action | What |
|--------------|------|
| `79b45eb` | **CI green** — llama.cpp `load_mode` dual-API (JNI) + npm overrides (`brace-expansion@5`, `sharp`) |
| `6cab16b` | Audit report `docs/audits/2026-08-04-ci-engineering-audit.md` |
| PRs #108–#113 | GitHub Actions bumps merged |
| PRs #132–#133 | UI + root npm **minor/patch** groups merged (CI full green) |
| Closed #116–#117, #119, #121–#122, #125–#126, #131 | Majors / failing — not required for software 100% |
| Remote delete | `wip/website-deploy-docs` (superseded: model switch already on main), empty legacy branches |

Local verify snapshot (pre-push of this handoff): catalog parity + 13/13 live URLs; full suites were green on `79b45eb` and Dependabot PRs re-ran green on tip.

---

## Facebook content machine

Pipeline: **strategy → generator → calendar → poster → cron.**

| File | Role |
|------|------|
| [`docs/FACEBOOK_STRATEGY.md`](FACEBOOK_STRATEGY.md) | positioning, voice, pillars |
| [`scripts/social-content.cjs`](../scripts/social-content.cjs) | bespoke posts |
| [`scripts/gen-social-posts.cjs`](../scripts/gen-social-posts.cjs) | → `docs/social/calendar.{json,md}` |
| [`scripts/post-to-facebook.cjs`](../scripts/post-to-facebook.cjs) | Graph API poster |
| [`.github/workflows/social-post.yml`](../.github/workflows/social-post.yml) | cron 14:00 UTC Mon/Wed/Fri |
| [`docs/social/FACEBOOK_SETUP.md`](social/FACEBOOK_SETUP.md) | owner token runbook |

- Dry-run: `node scripts/post-to-facebook.cjs --date 2026-07-27 --dry-run`  
- Poster **no-ops safely** without secrets.  
- English-only social for now (RU stream deferred).

### FB Page manual state (facebook.com/quenderin)

Done: About links (site, App Store, Android beta, GitHub), bio, category.  
Still manual: cover + profile images (paths above).

---

## Deploy (website)

Primary = Cloudflare **Worker** `quenderin` (account `wallmarketshq`), not Pages-only.

```bash
npx wrangler deploy --config wrangler.site.jsonc
npx wrangler pages deploy website --project-name=quenderin --commit-dirty=true
gh workflow run "Deploy website"
```

---

## Key links

- **App Store (iOS, live):** https://apps.apple.com/app/id6789854363  
- **Android beta:** https://play.google.com/apps/testing/ai.quenderin.app · group https://groups.google.com/g/quenderin-testers  
- **Repo:** https://github.com/alikatgh/quenderin · **Site:** https://quenderin.org  
- **FB:** https://facebook.com/quenderin  

---

## Gotchas

- **`android/keystore.properties`** is gitignored — never `git add -A` from pre-ignore history.  
- Memory under `~/.claude/…` is machine-local; this file carries cross-machine context.  
- Optional open PRs only: **#120** Electron 43, **#124** Gradle 9 — CI green, merge only with intentional smoke.
