# Handoff — pick up here

_Last updated: 2026-08-04 (usability wave)._  
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

### Highest-impact remaining product work (agent-doable)

1. **Real vision / photo understanding** — still ⏳ (mmproj / multimodal path). Large engine project.
2. **Russian/long Settings strings** — known localization gap (CHANGELOG).
3. **Live golden eval with real models** — structural gate exists; token-quality eval needs device/model.

### Owner-only (still)

Facebook secrets/images · store console pastes · physical-device tok/s · signing/notarize desktop · Play production.

---

## What shipped recently (engineering)

| When | What |
|------|------|
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
