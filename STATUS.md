# Quenderin — cross-platform status

An offline, on-device AI agent. The desktop app is the working prototype; native **iOS**
and **Android** are the destination. This is the one map of where everything stands and
how to verify it. (Deeper docs: `apple/REALITY.md`, `apple/MODEL_SELECTION.md`,
`apple/ARCHITECTURE.md`, `android/README.md`, `docs/`.)

## Platforms

| Platform | What's there | Engine | Verification |
|----------|--------------|--------|--------------|
| **Desktop** (Electron/TS) | Shipping prototype — full agent + chat | `node-llama-cpp` (real) | `npm run lint && npm run typecheck && npm run test:recommendation` |
| **iOS** (Swift) | M1–M4 brain + picker + SwiftUI; **app builds + runs on the simulator**; mock by default, **real `LlamaEngine` when llama.cpp is linked** | `LlamaEngine` (real llama.cpp C-API — **links + runs via xcframework**; `DefaultInferenceEngine.make()` picks it when `canImport(llama)`, else mock) | `cd apple/QuenderinKit && swift test` → **149 tests** (incl. real-inference test through the actual engine) |
| **Android** (Kotlin) | M1–M4 brain + picker; mock by default, **real `LlamaEngine` when `jni/llama.cpp` is present** | `LlamaEngine` (JNI to llama.cpp — **builds + runs**; `build.gradle.kts` auto-detects `jni/llama.cpp` → ships `libquenderin_llama.so`, else mock) | `android/quenderin-core` via bundled `kotlinc` → **99 checks**; `./gradlew :app:assembleDebug` → APK |

## Milestone parity (mobile brain — both run on mocks, fully tested)

| | M1 onboarding | M2 chat | M3 offline-ready | M4 agent loop | Model picker |
|---|:---:|:---:|:---:|:---:|:---:|
| **iOS** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Android** | ✅ | ✅ | ✅ | ✅ | ✅ |

- **M3** = Wi-Fi guard · disk-fit check · "safe to go offline" verdict · resume bookkeeping.
- **M4** = `AgentTool` + safe arithmetic · lenient JSON planner · `AgentLoop` (plan → safety-gate → execute → observe → repeat, live `onStep`) · `AgentSession` (bindable view-model) · `AgentView`/`AgentScreen` (the screen; iOS `RootView` gains an optional Agent tab).
- **Conversation history** = `ConversationManager`/`Library`/`Store` + a file-backed `ConversationPersistence` + a `ConversationCoordinator` (restore-recent · persist-per-turn · new · open · delete), wired into the Chat tab on both platforms (iOS `ChatHomeView` + History sheet; Android `ChatScreen` + History bottom sheet).

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

## The on-device cliff — crossed on both platforms

0. **Real on-device inference — ✅ PROVEN on iOS *and* Android (2026-06-14).** Both native
   engines were built against real llama.cpp and produced coherent inference end-to-end:
   - **iOS:** `QUENDERIN_LLAMA_DIR=… swift build` compiles the real `LlamaEngine` as part of
     QuenderinKit; the smoke test runs (~135 tok/s decode, CPU, M-series Mac).
   - **Android:** `android/verify-llama-link.sh` built `libllama.so` via the NDK, compiled the
     `jni/llama_jni.cpp` bridge, and ran inference **on a booted arm64 emulator** — coherent
     output, **~102 tok/s decode (CPU)**. The real-inference **APK** builds (`./gradlew
     :app:assembleDebug` with `jni/llama.cpp` present), installs, and the running app loads
     `libquenderin_llama.so` (`nativeloader: …ok`) so `NATIVE_AVAILABLE` is true and it uses
     the real engine. Both platforms auto-detect the native lib (iOS xcframework / Android
     `jni/llama.cpp`) and fall back to the mock when absent.

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
2. **Still needs PHYSICAL hardware (for ground-truth numbers only — the path is proven):**
   an iPhone for real Metal on-device tok/s + battery + thermals, and a physical Android
   phone for real-SoC tok/s. The Mac/sim/emulator numbers are host-CPU ceilings; only a real
   phone replaces the conservative, clearly-labeled chip-score estimates with ground truth.
   (The Android **NDK build + on-emulator run** is now done — see item 0.)
3. **Ship** — App Store / Play Store; fill the legal-page placeholders; grant the GitHub
   `workflow` token scope to enable the parked Pages deploy.

## Store readiness — software done; the rest needs *you*

Both native apps are **code-complete and compliance-clean in software**. The Generative-AI
content-safety surface is fully wired on iOS + Android: an unfiltered-output disclaimer, a
"Report this response" affordance (chat + agent), the agent's final answer + tool calls gated
by `SafetyBlocklist`, **chat output flagged** with a non-blocking warning when it trips the
blocklist (`ChatMessage.isFlagged` + `SupportContact.flaggedOutputNotice`, parity-checked), and
the agent now explains *why* it halted (`HaltReason.userMessage`). Store blockers that were code
(iOS `PrivacyInfo.xcprivacy`, Android FGS `<service>`, backup-exclusion, `ITSAppUsesNonExemptEncryption`)
are resolved and CI-gated.

**What's left is account/hardware/legal only — an agent can't do it.** The full ledger with
exact files and one-line actions is in **`docs/SHIP_READINESS.md`**; the short list: host the
privacy policy + paste the URL (the one remaining *blocker*), set a dedicated support email,
file 17+/Mature 17+, opt into Apple's Standard EULA, complete the Play Data-Safety form, and
capture real on-device tok/s on a physical phone.

Optional future product work: Android runtime manifest-loading (kotlinx.serialization in the app).
