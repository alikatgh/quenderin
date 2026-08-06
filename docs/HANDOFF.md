# Handoff — pick up here

_Last updated: 2026-08-06 (usability wave)._  
_(Agent memory is machine-local — this file is the cross-machine source of truth.)_

## TL;DR — **not** “product ready” yet

Ship/CI checklists can be green while the **day-one product still feels unfinished**. Treat
“software complete” in older audits as **engine/compliance ready**, not **usable for real people**.

| Layer | Honest state |
|-------|----------------|
| **iOS** | Live on App Store; real llama when xcframework linked. Empty chat now has starters. Still small-model quality ceiling. |
| **Android** | Closed beta; real inference only when `jni/llama.cpp` present in the build. Same UX gaps as iOS historically. |
| **Desktop Electron** | Research prototype — **not** the product (`docs/PRODUCT.md`). |
| **CI / catalog** | Green; 13 models parity + live URLs. |
| **First-run wait** | DownloadWaitPlayground (tips + mini-game + ETA) — shipped 2026-08-04. |
| **First chat** | Starter chips + auto-open first chat — shipped. |
| **Prefill honesty** | “Thinking · Ns” typing bubble — shipped. |
| **Small-model prompt** | Lead-with-answer / no-invent system prompt twins — shipped. |
| **ChatTier** | tiny/small/full maxTokens + prompt suffix — shipped. |
| **Engine honesty** | Demo banner + Settings row; release fails without native llama — shipped. |
| **Prefill phase** | Loading prompt vs Writing labels — shipped. |
| **Photo attach** | Honest vision-not-yet refusal; pickers accept images — shipped (real vision still ⏳). |
| **Golden chat gate** | Structural CI on starters/tiers/vision copy — shipped (`npm run check:golden-chat`). |
| **Desktop general prompt** | Lead-with-answer / no-invent + maxTokens 512 — shipped (aligned with mobile). |
| **Localization pass** | Engine honesty, generation phase, attach/vision help, download-wait strings in iOS catalog + Android ru/ko/ja/zh — shipped 2026-08-04. |
| **Localized starters** | Empty-chat chips + prompts in ru/ko/ja/zh — shipped (not English-only on first run). |
| **Empty-reply / Continue cues** | Locale-aware via `ChatUserFacing` (ru/ko/ja/zh) — shipped. |
| **Android copy message** | Long-press Copy + Report menu — shipped (parity with iOS). |
| **Demo mock replies** | Starter-aware canned answers + demo footer (no more one wall for every prompt) — shipped. |
| **Android model router** | First-message Switch suggestion + Settings routing toggle — shipped (iOS parity). |
| **Android Agent handoff** | Computer-task short-circuit + Open in Agent chip — shipped (iOS parity). |
| **Android low-quality heads-up** | Empty-chat warning for Low quant — shipped (iOS parity). |
| **RU ActionIntent** | Computer-task detection for Russian phrasing — shipped both platforms. |
| **Android Agent auto-run** | Open in Agent starts the run (iOS parity) — shipped. |
| **Android Settings i18n** | Section titles + speed/model rows localized — shipped. |
| **Guided handoff locale** | Computer-task education reply in ru/ko/ja/zh — shipped. |
| **Android Agent empty i18n** | Title, examples, working rows, recents — shipped. |
| **Picker + router reason i18n** | Model picker shell + localized route reasons — shipped. |
| **Image refusal locale** | Vision-not-yet copy in ru/ko/ja/zh — shipped. |
| **New chat + halt locale** | History empty title + agent halt banners — shipped. |

### Highest-impact remaining product work (agent-doable)

1. **Real vision / photo understanding** — still ⏳ (mmproj / multimodal path). Large engine project.
2. **Residual English** — some capability purpose strings / onboarding footnotes.
3. **Live golden eval with real models** — structural gate exists; token-quality eval needs device/model.

### Owner-only (still)

Facebook secrets/images · store console pastes · physical-device tok/s · signing/notarize desktop · Play production.

---

## What shipped recently (engineering)

| When | What |
|------|------|
| 2026-08-06 | UX: model picker + ModelRouter reason i18n |
| 2026-08-06 | Agent: Android empty-state + working rows i18n (ru/ko/ja/zh) |
| 2026-08-06 | Settings: Android section i18n + locale-aware guided handoff reply |
| 2026-08-06 | Agent: Android handoff auto-runs; iOS Continue/Today/Switch localization |
| 2026-08-06 | Chat: Android low-quality empty-state heads-up + RU ActionIntent patterns |
| 2026-08-05 | Chat: Android ActionIntent handoff (guided reply → Agent tab) |
| 2026-08-05 | Chat: DemoMockReplies + Android ModelRouter suggestion chip |
| 2026-08-05 | Chat: ChatUserFacing empty/continue locale packs + Android copy long-press |
| 2026-08-05 | Chat: localized first-run starters (ru/ko/ja/zh) |
| 2026-08-04 | i18n: engine/phase/wait strings + desktop general prompt parity |
| 2026-08-04 | CI: JNI `load_mode` dual-API + npm audit overrides |
| 2026-08-04 | UX: download wait playground (game + tips) iOS/Android/desktop |
| 2026-08-04 | UX: **ChatStarters** empty-state chips + download ETA |
| 2026-08-04 | Chat: Thinking·Ns, ChatTier, demo-mode honesty |
| 2026-08-04 | Android: **fail-closed release** without `jni/llama.cpp` |

---

## Key links

- App Store: https://apps.apple.com/app/id6789854363  
- Android beta: https://play.google.com/apps/testing/ai.quenderin.app  
- Product thesis: `docs/PRODUCT.md`  
- Failure ledger: `docs/KNOWN_FAILURE_MODES.md`  
- Site: https://quenderin.org  
