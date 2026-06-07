# QuenderinKit

The portable **"brain"** of Quenderin's offline-autonomy vision, in pure Swift.

Quenderin's destination is a native mobile app (Swift on iOS, native on Android)
that, on first launch, **probes the device's hardware** and **auto-downloads the
right model "modules"** so the user goes from *install → ready-to-use local AI*
with zero configuration. This package is step one of that: the device-detection
→ module-selection layer, lifted out of the Electron/TypeScript prototype and
ported to Swift so it compiles into the iOS app and unit-tests on macOS.

## What's here

| File | Role |
|------|------|
| `HardwareProbe.swift` | Reads RAM / cores / chip / Apple-Silicon via Foundation + `sysctl`. Works on macOS and iOS. |
| `ModelCatalog.swift` | The downloadable modules, quantization table, and RAM-tier bands. Mirrors `quenderin/src/constants.ts`. |
| `ModelRecommender.swift` | `device RAM → recommended module`. 1:1 port of `getRecommendedModelIdForTotalRam` / `getHardwareRecommendation`. |
| `MemoryFitness.swift` | "Can this device load this model?" with the same 0.85 / 0.65 budgets and size-scaled overhead as desktop. |

## Provenance — keep in sync with desktop

The catalog, RAM tiers, and recommendation thresholds are a direct port of the
TypeScript app. The boundary tests in `Tests/QuenderinKitTests/ModelRecommenderTests.swift`
mirror `quenderin/tests/recommended-model.test.ts` exactly (1.5 / 3 / 6 GB
thresholds), so the desktop and mobile clients recommend the **same** model for
the **same** hardware. If you change one catalog, change the other.

## Build & test

```bash
swift build      # compiles for the host (macOS) — warning-free
swift test       # 13 tests, runs in milliseconds, no simulator needed
```

## Inference

`InferenceEngine` is the runtime-agnostic seam. Two conformers ship today:

- `MockInferenceEngine` — canned streaming, for previews/tests/app bring-up.
- `LlamaEngine` — the real **llama.cpp** adapter. llama.cpp stays C/C++; this is
  the thin Swift layer that calls its C API. The C calls live behind
  `#if canImport(llama)`, so the package builds **now** and the engine fails
  cleanly until you link llama.cpp (see the wiring notes in `LlamaEngine.swift`).
  The C path is a verified-on-device starting point — `swift test` covers only
  the fallback, not real inference (which needs the `llama` module + a GGUF model
  + a device/simulator).

## Onboarding (Milestone M1)

The "download → ready" spine, fully wired against the seams:

- `ModelDownloader` (+ `URLSessionModelDownloader`, `MockModelDownloader`) —
  streamed-progress download to disk.
- `OnboardingModel` — `@MainActor` state machine: probe → recommend → download →
  load → ready (or failed). Depends only on the downloader + engine protocols, so
  it's unit-tested end-to-end with mocks.
- `OnboardingView` — SwiftUI screen rendering each phase.

See `../ROADMAP.md` for the goal, status table, and the app-target snippet.

## Also here (M2)

- `ChatModel` + `ChatView` — streaming chat against any `InferenceEngine`.
- `ModelPickerView` + `ModelCatalog.optionsWithFitness(...)` — Tier-2 "choose a
  model" screen that grays out models that won't fit the device.
- `SafetyBlocklist` — the agent's hard sandbox (Pay/Delete/Password…).
- `ModelManifest` — versioned Codable JSON, the seed of a cross-platform catalog.
- `RootView` — onboarding → chat. The `../QuenderinApp` target wires `@main`.

The whole flow runs today on `MockInferenceEngine` + `MockModelDownloader`.

## Offline-Ready (M3)

For someone about to lose internet, the *download* is the make-or-break moment:

- `DiskSpace` — will the model fit? (size estimated from params × quant bits, 300 MB margin)
- `DownloadPolicy` + `NetworkStatus` — Wi-Fi-only guard; never start on no connection.
- `BackgroundModelDownloader` + `DownloadStore` — a **background** URLSession that
  survives the app being suspended, with persisted progress that resumes after
  relaunch (the foreground downloader's fatal flaw, fixed).
- `OfflineReadiness` / `Preflight` + `OfflineReadinessView` — a verifiable
  **✅ "safe to go offline"** signal: model fully downloaded + disk OK, with a
  plain-language list of any remaining blockers.

Logic fully tested; live background download + real connectivity need a device.

## Not yet here (next steps)

- **Link llama.cpp + run on device** — add the `llama` SwiftPM product /
  xcframework, run `LlamaEngine` on a simulator with a small GGUF. The only piece
  that can't be proven headlessly. **Step-by-step: [`INTEGRATION.md`](INTEGRATION.md).**
- **Generate the app project** — `brew install xcodegen && cd ../QuenderinApp && xcodegen`.
- **Real-device perf + battery** — measure tok/s + power on devices; recommend
  *usable* models, not just loadable ones.
- **Ship it** — Apple Developer account, signing, TestFlight, App Store review.
- **M4 agent loop** — perception → plan → execute (safety blocklist already done).
