# The agent, across platforms — authoritative reference

A single source of truth for what the on-device agent does on each platform and **why** the differences
exist. The per-feature audit reports in `docs/audits/` are point-in-time; this is the living matrix.
Last consolidated 2026-07-09.

Platforms: **Apple** = macOS/iOS Swift (`apple/QuenderinKit`) · **TS** = Windows/Linux/CLI TypeScript
(`src/services/capability/capabilityAgent.ts`) · **Android** = Kotlin (`android/quenderin-core`).

## The reliability spine — consistent across ALL three

| Behavior | Apple | TS | Android | Notes |
|---|:-:|:-:|:-:|---|
| Goal re-anchor at the transcript tail every turn | ✅ | ✅ | ✅ | Byte-identical text; the named fix for multi-step drift |
| Decision parsing, `answer > plan > tool` precedence, strict plans | ✅ | ✅ | ✅ | Machine-guarded by `scripts/check_agent_parity.py` (19 vectors) |
| Stall guard (nudge on 1st repeat, halt on 2nd) | ✅ | ✅ | ✅ | |
| Parse-failure guard (nudge once, halt on 2nd) | ✅ | ✅ | ✅ | |
| Zero-action guard (action goal answered with 0 tools → nudge → halt) | ✅ | ✅ | ✅ | TS gained it 2026-07-08 (`ActionIntent` twin) |
| Anti-narration preamble line | ✅ | ✅ | ✅ | TS gained it 2026-07-08 |
| `.plan` per-step safety gating | ✅ | ✅ | ✅ | |
| Grammar-forced decode + action-first grammar on step 1 | ✅ | ✅ | ✅ | Android gained it 2026-07-09 (grammar-in-JNI) |
| Deliberation ("think, then decide"), off by default | ✅ | ✅ | ✅ | TS + Android both gained it this session |
| Skill memory (record proven tool sequences → prime similar goals) | ✅ | ✅ | 🔄 | TS was the original; Apple gained it 2026-07-09 (`45f4c45`); Android port in flight (converging on the same `recallSkills`/`recordSkill` seam) |

Skill-memory notes: pure `SkillMemory` policy is a byte-faithful twin (ASCII `[a-z0-9]` tokenization,
overlap-coefficient similarity, 300-char goal / 40-tool caps); each platform keeps its own persistence edge
(desktop `agent-skills.json`, Apple UserDefaults, Android SharedPreferences). It's a HINT the model still
reasons over — every recalled step still passes the full gate — so it's safe on by default (not an
experimental flag). The `AgentLoop` seam is two injected closures (`recallSkills`/`recordSkill`, default
no-ops) so the loop stays pure and the app owns the store.

## Intentional divergences — NOT drift, do not "fix"

| Feature | Where | Why it's scoped there |
|---|---|---|
| Recipes + live honest checklist + **dynamic planning** | **Apple only** | A macOS UX layer (a checklist surface + curated chains). The shared spine is the re-anchor, which IS everywhere. See [`docs/audits/2026-07-08-dynamic-planning.md`], `memory:dynamic-planning-scope`. |
| `needsPermission` halt + made-but-all-refused "fabricated-success" withhold | **Apple + Android** | TS deliberately returns the model's *honest* answer on an all-refused run (fail-closed dashboard / user decline) rather than a permission banner — a product decision; the guard can't tell an honest "I couldn't" from a fabricated "done". Attempted + reverted 2026-07-08; see [`docs/audits/2026-07-08-agent-loop-parity.md`]. |

## What's proven vs. unproven
- **Proven, on by default:** re-anchor, all guards, grammar-forced decode (Apple/Android/TS), the honest
  recipe checklist (Apple). These are reliability wins verified in tests + (Apple) live.
- **Unproven, off by default (flag/toggle):** dynamic planning (Apple), deliberation (all 3). Shipped dark
  so plan/think quality can be measured on the real on-device model before any default-on decision. The
  real quality ceiling is the model (a 4B), not the mechanism — see `memory:agent-quality-is-model-bound`.
  The **open Hugging Face catalog** (Apple) is the lever that lets a user run a more capable model.

## Verification story (how each platform is checked in CI)
- **Apple:** `swift test` (QuenderinKit, ~443 tests) — compiles the SwiftUI views too.
- **TS:** `vitest` (~523 tests) + `tsc` + `eslint`.
- **Android:** `kotlinc` compiles the pure-Kotlin core + **runs `CoreVerify`**; `assembleDebug` builds the
  Compose app; **`mobile-android-jni`** syntax-checks `llama_jni.cpp` against real llama.cpp headers (the
  native path can't be built on a disk-limited dev box, so CI is the compile net + iOS is the runtime
  reference — `llama_sampler_sample` accepts the token, so a grammar sampler advances identically to iOS).
- **Cross-platform:** `scripts/check_agent_parity.py` asserts a bijection over the decision-parser +
  blocklist vectors (iOS ⇄ Android). It does NOT cover guard/preamble/halt text — that parity is audited by
  hand (`docs/audits/2026-07-08-agent-loop-parity.md`).

## Known next steps (need on-device measurement or a product call, not more code)
1. Measure dynamic-planning + deliberation quality on the real qwen3-4b; decide default-on per platform.
2. If deliberation proves out, revisit the TS decline-UX product decision.
3. quenderin.org apex (Worker) deploy is a manual, authorized step (`scripts/deploy_website.sh`).
