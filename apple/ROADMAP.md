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
| llama.cpp adapter | ✅ `LlamaEngine` scaffold (C path needs device to verify) |
| **Model downloader** | ✅ `ModelDownloader` + URLSession impl + mock, mock tested |
| **Onboarding orchestration** | ✅ `OnboardingModel` state machine, tested |
| **SwiftUI onboarding shell** | ✅ `OnboardingView` (compiles; render needs simulator) |
| Link llama.cpp + run on device | ⛔ **needs you** — dependency + GGUF + simulator |
| Wrap as an Xcode app target | ⛔ needs Xcode (see "Running" below) |

## The verification cliff

Everything marked ✅ is proven by `swift test` on a Mac — no simulator, no
model file. The ⛔ items cross into "needs a real device + a multi-GB model,"
which is hands-on work only you can run. The code is written and degrades
cleanly until then (the app runs on `MockInferenceEngine` today).

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

## Next milestones (after M1)

- **M2 — Chat:** stream tokens from the loaded model into a SwiftUI chat view.
- **M3 — Agent loop:** port perception → plan → execute with the safety blocklist.
- **M4 — Android:** Kotlin app + JNI adapter over the *same* llama.cpp.
- **Shared manifest:** lift the catalog into language-neutral JSON read by TS + Swift + Kotlin.
