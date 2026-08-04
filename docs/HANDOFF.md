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

### Highest-impact remaining product work (agent-doable)

1. **Android real-inference default** — many builds ship mock unless NDK/llama is wired; users “chat” with nothing real.
2. **Per-tier system prompts / maxTokens** — even tighter for 1B vs 7B.
3. **Vision / photo** — still ⏳ (KNOWN_FAILURE_MODES); documents-as-text only.
4. **Prefill phase split** — “Loading prompt…” vs “Writing…” if engine exposes prefill/decode.
5. **Russian/long Settings strings** — known localization gap (CHANGELOG).
6. **Desktop chat starters** — mobile got them first; Electron wizard/chat still thinner.

### Owner-only (still)

Facebook secrets/images · store console pastes · physical-device tok/s · signing/notarize desktop.

---

## What shipped recently (engineering)

| When | What |
|------|------|
| 2026-08-04 | CI: JNI `load_mode` dual-API + npm audit overrides |
| 2026-08-04 | UX: download wait playground (game + tips) iOS/Android/desktop |
| 2026-08-04 | UX: **ChatStarters** empty-state chips + download ETA |

---

## Key links

- App Store: https://apps.apple.com/app/id6789854363  
- Android beta: https://play.google.com/apps/testing/ai.quenderin.app  
- Product thesis: `docs/PRODUCT.md`  
- Failure ledger: `docs/KNOWN_FAILURE_MODES.md`  
- Site: https://quenderin.org  
