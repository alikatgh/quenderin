# Changelog

## 0.2.0 — iOS on the App Store (2026-07-20)
- **Quenderin: Offline AI Chat is live on the App Store** — free, on iPhone, worldwide (175 regions):
  <https://apps.apple.com/app/id6789854363>. The native SwiftUI app, fully offline and on-device —
  our first public store release. (The Mac App Store build follows once its review clears.)

## Unreleased

### Android chat→Agent handoff (usability parity)
- **ActionIntent short-circuit on Android chat**: computer-task prompts get a guided reply +
  **Open in Agent** chip (no “I cannot fulfill…” wall). `AgentHandoff` baton switches tab and
  fills the Agent goal field (user still taps Run — ask-before-act).
- `ChatModel.recordGuidedTurn` + `ActionIntent.displayAssistantText` twins of iOS.

### Demo mock feels usable + Android model router (usability)
- **DemoMockReplies** (iOS + Android): when no native llama is linked, starter-like prompts
  (math, packing, jet lag, dinner ideas, email) get a short useful canned answer **plus** an
  honest demo footer — not a single frozen “canned until linked” wall for every tap.
- **Android ModelRouter chip**: empty-chat first draft (≥12 chars) offers Switch to the best
  installed model (never silent). Settings → Routing toggle (`suggestBestModel`, default on).

### Chat recovery + copy parity (usability)
- **Locale-aware empty-reply notice + continue cue** (`ChatUserFacing` twins): zero-token and token-cap
  recovery no longer force English into a Russian (ko/ja/zh) chat.
- **Android long-press menu**: Copy + Report (was Report-only on long-press) — parity with iOS context menu.

### Localization + desktop prompt parity (usability)
- **iOS string catalog**: engine honesty, Loading prompt / Writing phase, attach help (vision not yet),
  demo banner, Send/Stop a11y — keys in `scripts/translations.tsv` → `Localizable.xcstrings`.
  Source uses `String(localized:)` where `String` params used to skip the catalog.
- **Android locales** (ru/ko/ja/zh-rCN): filled 28 missing keys — demo mode, engine row, generation
  phase, chat starters a11y, download-wait playground tips/scores.
- **Localized chat starters** (ru/ko/ja/zh): empty-chat chips + prompts resolve to the UI language so
  Russian-first users are not forced into English on first message (iOS `offlineChat(locale:)`,
  Android `offlineChat(languageCode)`).
- **Desktop general preset**: system prompt aligned with mobile ConversationContext (lead-with-answer,
  no invent); `maxTokens` 512 (was 2048) to curb ramble on small local models.

### Prefill phase + honest photo refusal + golden chat gate
- **GenerationPhase** (`loadingPrompt` → `writing`) drives “Loading prompt · Ns” / “Writing · Ns”
  (iOS + Android typing bubbles). Desktop shows “Loading prompt · Ns” during prefill.
- **Image attach** refused with an explicit vision-not-available message (not “isn’t a text file”).
  Pickers now **accept images** so that refusal is reachable (iOS + Android).
- **`shared/golden-chat-prompts.json`** + `npm run check:golden-chat` CI gate (starters,
  tiers, vision refusal copy).

### Ship path: no silent mock releases
- **Android release/bundle fails** without `jni/llama.cpp` (escape: `-Pquenderin.allowMockRelease=true`).
- **BuildConfig.QUENDERIN_HAS_NATIVE_LLAMA** + Settings “Inference engine” row (real vs demo).
- Mock canned reply no longer pretends to be real on-device AI (iOS + Android).

### ChatTier + honest demo mode
- **ChatTier** (tiny ≤2B / small ≤5.5B / full): shorter maxTokens + tighter prompt for small models
  (iOS GenerationOptions + Android LlamaEngine override).
- **Demo-mode banner** when the build has no native llama (mock engine) — no more fake “on-device” chat.
- Desktop empty-state suggestions aligned with mobile offline starters; Thinking · Ns on desktop too.

### Chat feels alive during prefill + sharper small-model prompt
- **“Thinking · Ns”** on the typing bubble (iOS + Android) so multi-second prefill isn’t a frozen UI.
- **System prompt** rewritten for 1–4B: lead with the answer, short bullets, no inventing facts/URLs/tool
  results, language-mirror + Agent redirect kept (twins in sync).
- **Android:** failed generation shows **Retry** (restores last prompt into the composer).

### Day-one usability (empty chat is no longer a blank stare)
- **Starter chips** on empty chat (iOS + Android): Summarize, Rewrite, Translate, Brainstorm,
  Explain simply, Quick math, Draft email, Packing list — prompts tuned for 1–4B offline models.
  Paste-ready chips fill the composer; complete prompts send in one tap.
- **Auto-open first chat** after onboarding when there is no history (skip empty Chats list).
- **Download ETA** (~N min left) from recent throughput on the wait playground.

### Download wait is no longer a dead screen
- **Catch-the-tokens mini-game + rotating tips** while the first model downloads (iOS, Android,
  desktop wizard). Sticky progress stays visible; multi-GB installs used to strand users on a
  percentage ring only.
- **Desktop:** setup wizard can continue (voice step) while the model keeps downloading in the
  background — no more disabled “Next” trap.

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
- **Localized UI (macOS + iOS)**: 280-key string catalog (`scripts/translations.tsv` →
  `build_xcstrings.py` → `Localizable.xcstrings`, wired into both app targets) — Russian first,
  then ko/ja/zh-Hans filled. Known gap: long Settings captions built from concatenated
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
