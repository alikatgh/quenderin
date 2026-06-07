# Quenderin Apple — Roadmap

## 🎯 Goal: Milestone M1 — First-Run Onboarding

> A fresh install **probes the device → recommends a model → downloads it →
> loads it → reaches "Ready"** — fully on-device, zero configuration.

This is the smallest end-to-end slice of the vision: *download the app, and it
just works on your hardware.* Everything else (chat UI, agent loop, Android)
builds on this spine.

## Status

| Piece | State |
|-------|-------|
| Hardware probe (RAM / chip) | ✅ `HardwareProbe`, tested |
| Model catalog + RAM tiers | ✅ `ModelCatalog`, tested |
| Recommendation (device → model) | ✅ `ModelRecommender`, tested (matches desktop) |
| Memory fitness check | ✅ `MemoryFitness`, tested |
| Inference seam | ✅ `InferenceEngine` + `MockInferenceEngine`, tested |
| llama.cpp adapter | ✅ `LlamaEngine` — **C path PROVEN**: type-checks vs real llama.cpp + runs inference on Mac Metal & iPhone sim (`apple/verify-llama-link.sh`) |
| Model downloader | ✅ `ModelDownloader` + URLSession impl + mock, mock tested |
| Onboarding orchestration | ✅ `OnboardingModel` state machine, tested |
| SwiftUI onboarding shell | ✅ `OnboardingView` (compiles; render needs simulator) |
| Safety blocklist | ✅ `SafetyBlocklist` (Pay/Delete/Password…), tested |
| Shared manifest schema | ✅ `ModelManifest` (Codable JSON), round-trip tested |
| **Tier-2 model picker** | ✅ `ModelPickerView` + fitness gating, tested |
| **Streaming chat (M2)** | ✅ `ChatModel` + `ChatView`, tested on mock |
| **App shell** | ✅ `RootView` + `QuenderinApp` target + xcodegen spec |
| Link llama.cpp + run inference | ✅ **PROVEN** — real llama.cpp, Mac Metal (~177 tok/s) + iPhone 16 simulator (~160 tok/s); coherent output |
| Real on-*phone* tok/s + battery | ⛔ **needs you** — a physical iPhone (Mac/sim numbers are a ceiling) |
| Generate .xcodeproj + run the app | ⛔ needs you — `brew install xcodegen && xcodegen` |

## The verification cliff — crossed

Everything marked ✅ is proven by `swift test` on a Mac. The llama.cpp link —
long *the* "needs a device" cliff — is now **proven by execution**:
`apple/verify-llama-link.sh` builds real llama.cpp, type-checks `LlamaEngine`'s
real `#if canImport(llama)` path against current master, and runs **coherent
inference on Mac Metal and a booted iPhone 16 simulator**. It even caught + fixed
a real dangling-pointer bug in that path. What genuinely still needs *you*: a real
iPhone for on-phone tok/s/battery, the xcframework packaging (Route A in
INTEGRATION.md), and the App Store. The app runs on `MockInferenceEngine` until
you flip the two lines in `QuenderinApp.init()`.

## Running the onboarding flow today (on the mock engine)

`OnboardingModel` + `OnboardingView` are usable right now from an Xcode app
target:

```swift
import SwiftUI
import QuenderinKit

@main
struct QuenderinApp: App {
    @StateObject private var model = OnboardingModel(
        downloader: MockModelDownloader(),   // swap for URLSessionModelDownloader for real downloads
        engine: MockInferenceEngine()        // swap for LlamaEngine() once llama.cpp is linked
    )
    var body: some Scene {
        WindowGroup { OnboardingView(model: model) }
    }
}
```

Swap the two mocks for `URLSessionModelDownloader()` and `LlamaEngine()` to go
real — no other code changes, because both sit behind protocol seams.

## Milestones

- ✅ **M1 — Onboarding:** probe → recommend → download → load → ready.
- ✅ **M2 — Chat:** stream tokens from the loaded model into a SwiftUI chat view.
- ✅ **M3 — Offline-Ready:** make the pre-trip download trustworthy for someone
  about to lose internet — `DiskSpace` (room check), `DownloadPolicy` (Wi-Fi-only
  guard), `BackgroundModelDownloader` + `DownloadStore` (survives suspension /
  resumes after relaunch), and `OfflineReadiness` / `Preflight` (a verifiable
  "✅ safe to go offline" signal). Logic all tested; live background download +
  real connectivity need a device.
- ✅ **M4 — Agent core:** an on-device **tool-use** loop (`AgentLoop`): plan (via
  `InferenceEngine`) → safety-gate (`SafetyBlocklist`) → run a tool → observe →
  repeat → answer. Ships `CalculatorTool`/`EchoTool`, lenient JSON planner
  parsing (`AgentDecision`), and `ScriptedInferenceEngine` for deterministic
  tests. Fully tested. (Driving *other apps* is intentionally out of scope — iOS
  sandboxes that; the agent acts through tools it owns. Real planning quality
  needs llama.cpp linked.)
- **M5 — Android:** Kotlin app + JNI adapter over the *same* llama.cpp.
- **Shared manifest:** `ModelManifest` schema is done; next, emit it from the
  desktop TS app so all three platforms read one JSON instead of hand-syncing.

> The whole onboarding → chat flow runs **today** on `MockInferenceEngine` +
> `MockModelDownloader` (see `RootView` / `QuenderinApp`). Only real on-device
> inference is gated on linking llama.cpp.
