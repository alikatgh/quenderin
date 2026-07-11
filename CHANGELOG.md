# Changelog

## Unreleased

### Paged MoE — frontier-class agent quality on 16 GB machines
- **New catalog flagship: Qwen3.6 35B MoE** (`qwen36-35b-a3b`, UD-IQ3_XXS, 13.2 GB, sha256-pinned,
  all platforms + shared manifest). Only ~3B of 35B params run per token, so with mmap the OS page
  cache streams the experts from disk — measured 17.3 tok/s on a 16 GB M4 (CPU-only, 4–6 GB
  resident, zero swap). Directly attacks the "agent quality is model-bound" ceiling.
- **`MoEShape` (Swift):** detects the `…-35B-A3B` naming convention and estimates the paged
  RESIDENT set — open-catalog search & fitness no longer tell a 16 GB Mac that a runnable
  13 GB MoE "needs 20 GB". Filters gate MoE by ACTIVE params (size class per token) while
  download caps stay honest on total size.
- **GPU offload is now a policy, not a constant:** Swift `GpuOffloadPolicy` (twin of Android's
  `GpuOffloadPlanner`) keeps Metal offload when weights fit the app budget and goes CPU-only
  + mmap when they don't (wiring an over-budget file thrashes the Metal working set); desktop
  `gpuOffloadFits` does the same before trying GPU.
- Agent-screen upgrade copy is MoE-honest (13 GB download, SSD-streamed) — never the generic
  "slightly slower replies". `check_catalog_parity.py` fixed to parse hyphenated quant ids.

### Russian-first: UI localization + honest model-language info
- **Russian UI (macOS + iOS)**: 240-key string catalog (`scripts/translations.tsv` →
  `build_xcstrings.py` → `Localizable.xcstrings`, wired into both app targets). ko/ja/zh-Hans now filled too
  columns are scaffolded, pending. Known gap: long Settings captions built from concatenated
  literals are verbatim strings (SwiftUI skips localization) — needs a source-side pass.
- **Every catalog model states its languages** (`languages` field, all platforms + manifest,
  decode-safe for older persisted entries) — shown in the model profile, localized. Honest
  about Russian: the Llama 3.2 tier says "no Russian" out loud (a 1B answered a Russian user
  in English — the info was missing where the choice is made).
- **Chat prompt mirrors the user's language** on all three platforms ("Always reply in the
  same language the user writes in") — small models default to English otherwise.

### Autopilot — run a goal without babysitting it (macOS)
- **"Allow all steps for this goal"** on the per-step approval dialog: one grant covers the
  rest of the run; the broker resets at the next goal, so it never leaks.
- **Settings → Agent → Autopilot**: goals start pre-approved from step 1 (for runs you can't
  sit in front of). What it never skips: the SafetyBlocklist (refuses before approval is even
  consulted), standing consent tiers, the audit ledger, and undo. Off by default.
- New `scripts/build_mac_dmg.sh` — local-test DMG in one command (build → sign consistently →
  package); fixes the hardened-runtime/adhoc Team-ID launch crash.

## 0.2.0 — 2026-07-09

### Distribution
- **Version alignment:** desktop (`package.json`), Android (`0.2.0` / versionCode 2), Apple
  marketing version `0.2.0` / build 2.
- **Windows dual channel:** GitHub Releases keep Setup + Portable `.exe`; Microsoft Store path
  via AppX (`npm run electron:build:win:store`) — full owner guide
  [`docs/MICROSOFT_STORE.md`](docs/MICROSOFT_STORE.md).
- **macOS public product:** native **QuenderinMac** App Store only (free listing for branding) —
  [`docs/MAC_APP_STORE.md`](docs/MAC_APP_STORE.md). Electron mac remains lab-only; CI desktop
  release stays Windows + Linux only.
- Website `download.html` updated for Store policy + v0.2.x.

### Product-path engineering (desktop / core)
- Sampling profiles: shared JSON + CI parity; packaged Electron loads `shared/` with embedded
  fallback.
- Android PDF text extract (pure-Kotlin) + FlateDecode; desktop sampling + golden chores in CI.
- GUI reliability: `verify()` on type/key/menu (TS + Swift).
- Skill memory: record/recall **tool + input** sequences (`recordSteps` / `formatHint`).
- Chore breadth: `fs.organize` (batch by type, durable undo), `fs.collect` (multi-file read for
  summarize → `fs.write` reports).

### Notes for owners cutting the release
1. Tag `v0.2.0` → GitHub Actions publishes Win/Linux installers.
2. On Windows: fill Partner Center identity in `electron-builder.yaml` `appx.*`, then
   `npm run electron:build:win:store` and follow MICROSOFT_STORE.md.
3. On Mac: `docs/MAC_APP_STORE.md` for App Store Connect upload of QuenderinMac 0.2.0 (2).

## 0.1.0 — earlier

First public desktop preview (Windows/Linux installers), native mobile software-complete baseline.
