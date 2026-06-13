# Quenderin — cross-platform status

An offline, on-device AI agent. The desktop app is the working prototype; native **iOS**
and **Android** are the destination. This is the one map of where everything stands and
how to verify it. (Deeper docs: `apple/REALITY.md`, `apple/MODEL_SELECTION.md`,
`apple/ARCHITECTURE.md`, `android/README.md`, `docs/`.)

## Platforms

| Platform | What's there | Engine | Verification |
|----------|--------------|--------|--------------|
| **Desktop** (Electron/TS) | Shipping prototype — full agent + chat | `node-llama-cpp` (real) | `npm run lint && npm run typecheck && npm run test:recommendation` |
| **iOS** (Swift) | M1–M4 brain + picker + SwiftUI; mock by default, **real `LlamaEngine` when llama.cpp is linked** | `LlamaEngine` (real llama.cpp C-API — **links + runs**; `DefaultInferenceEngine.make()` picks it when built with `QUENDERIN_LLAMA_DIR`/xcframework, else mock) | `cd apple/QuenderinKit && swift test` → **90 tests** |
| **Android** (Kotlin) | M1–M4 brain + picker, on the mock engine | `LlamaEngine` (JNI to llama.cpp — **not yet linked**) | `android/quenderin-core` via bundled `kotlinc` → **99 checks** |

## Milestone parity (mobile brain — both run on mocks, fully tested)

| | M1 onboarding | M2 chat | M3 offline-ready | M4 agent loop | Model picker |
|---|:---:|:---:|:---:|:---:|:---:|
| **iOS** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Android** | ✅ | ✅ | ✅ | ✅ | ✅ |

- **M3** = Wi-Fi guard · disk-fit check · "safe to go offline" verdict · resume bookkeeping.
- **M4** = `AgentTool` + safe arithmetic · lenient JSON planner · `AgentLoop` (plan → safety-gate → execute → observe → repeat, live `onStep`) · `AgentSession` (bindable view-model) · `AgentView`/`AgentScreen` (the screen; iOS `RootView` gains an optional Agent tab).

## Model picking — world-class, device-aware, measured

Not a RAM-band heuristic. Each platform gates on **per-app memory budget** (iOS jetsam /
Android native-heap — not total RAM), **chip throughput**, and **disk**, then defaults to
the largest *comfortable* model and surfaces a **heat/battery** expectation. Chip scores
are anchored to measured 2024–2026 data (`apple/REALITY.md`).

- iPhone SE/12/13 → 1B · iPhone 13 Pro/15/16 Pro → Qwen3 4B (7B offered, tight).
- Android adds 12–16 GB flagships → **Mistral 7B** (a default no 8 GB iPhone can hold).
- The honest truth: bursty chat is light; **sustained/agent loops throttle 10–44% and
  drain ~15–25%/hr — the agent-loop ceiling is heat, not memory.**

## One catalog, three platforms

The 11-model catalog is hand-maintained in desktop TS / iOS Swift / Android Kotlin but
**enforced in sync**: `shared/model-catalog.json` is the canonical manifest (desktop emits
it via `npm run gen:catalog` or `src/manifest.ts`; iOS decodes it). Guardrails:
`npm run check:catalog-parity` (cross-language) + `npm run test:manifest` (JS-native).

## Verify everything

```sh
# Desktop
npm run lint && npm run typecheck && npm run test:recommendation \
  && npm run test:manifest && npm run check:catalog-parity
# iOS
cd apple/QuenderinKit && swift test
# Android (no Gradle needed for the core)
cd android/quenderin-core && bash "$KOTLINC" src/main/kotlin/ai/quenderin/core/*.kt \
  src/verify/CoreVerify.kt -include-runtime -d /tmp/q.jar && java -jar /tmp/q.jar
```

## The on-device cliff — mostly crossed

1. **Link llama.cpp + run inference — ✅ PROVEN (iOS), now as the package default.**
   `apple/verify-llama-link.sh` builds real llama.cpp, compiles QuenderinKit's exact
   `LlamaEngine` C-API sequence against it, and runs a real inference: coherent output
   ("the sky is blue because…") on **macOS Metal (~177 tok/s)** AND on a **booted iPhone 16
   simulator (~160 tok/s, CPU)**. Re-verified 2026-06-13 end-to-end here via
   `QUENDERIN_LLAMA_DIR=… swift build` (the real `LlamaEngine` compiles **as part of the
   package**) + the smoke test (~135 tok/s decode, **CPU**, M-series Mac — no Metal toolchain
   in CommandLineTools, so this is a CPU floor, not the Metal number). The default-selection
   seam now exists: `DefaultInferenceEngine.make()` returns the real engine when
   `canImport(llama)` and the mock otherwise — **both build paths verified** (`swift build`
   with and without `QUENDERIN_LLAMA_DIR`). What remains is shipping the per-arch **xcframework**
   so a normal Xcode/device build links llama.cpp without `QUENDERIN_LLAMA_DIR`.
2. **Still needs PHYSICAL hardware:** an iPhone for real Metal on-device tok/s + battery +
   thermals (the Mac/sim numbers are host-CPU/Metal ceilings), and the Android NDK build run
   on a device. These replace the conservative, clearly-labeled chip-score estimates with
   ground truth.
3. **Ship** — App Store / Play Store; fill the legal-page placeholders; grant the GitHub
   `workflow` token scope to enable the parked Pages deploy.

Product decisions still open: wire `AgentSession` into a UI tab (agentic chat?), and
optional Android runtime manifest-loading (kotlinx.serialization in the app).
