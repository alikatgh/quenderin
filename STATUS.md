# Quenderin — cross-platform status

An offline, on-device AI agent. The desktop app is the working prototype; native **iOS**
and **Android** are the destination. This is the one map of where everything stands and
how to verify it. (Deeper docs: `apple/REALITY.md`, `apple/MODEL_SELECTION.md`,
`apple/ARCHITECTURE.md`, `android/README.md`, `docs/`.)

## Platforms

| Platform | What's there | Engine | Verification |
|----------|--------------|--------|--------------|
| **Desktop** (Electron/TS) | Shipping prototype — full agent + chat | `node-llama-cpp` (real) | `npm run lint && npm run typecheck && npm run test:recommendation` |
| **iOS** (Swift) | M1–M4 brain + picker + SwiftUI, on the mock engine | `LlamaEngine` (JNI to llama.cpp — **not yet linked**) | `cd apple/QuenderinKit && swift test` → **90 tests** |
| **Android** (Kotlin) | M1–M4 brain + picker, on the mock engine | `LlamaEngine` (JNI to llama.cpp — **not yet linked**) | `android/quenderin-core` via bundled `kotlinc` → **67 checks** |

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

## The on-device cliff (what genuinely needs hardware/accounts)

Everything provable without a phone is done and green. What remains needs you:

1. **Link llama.cpp** — iOS xcframework (`apple/QuenderinKit/INTEGRATION.md`) / Android NDK
   (`android/INTEGRATION.md`) — and run on a device/simulator with a real GGUF. Both apps
   auto-switch from the mock to the real engine the moment the binary is present.
2. **Measure** real tok/s, TTFT, battery, thermals → replace the interpolated chip scores
   with ground truth (the scores are conservative, clearly-labeled estimates today).
3. **Ship** — App Store / Play Store; fill the legal-page placeholders; grant the GitHub
   `workflow` token scope to enable the parked Pages deploy.

Product decisions still open: wire `AgentSession` into a UI tab (agentic chat?), and
optional Android runtime manifest-loading (kotlinx.serialization in the app).
