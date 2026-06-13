# Building & running the native apps (iOS + Android)

How to take the Swift (`apple/`) and Kotlin (`android/`) apps from source to a running
install. Two tiers per platform:

- **Bring-up (mock engine)** — the whole UI flow (onboarding → chat → agent) runs with no
  model file. Fastest way to see the app on a device/simulator.
- **Real on-device inference** — link llama.cpp so the app actually generates tokens.

> **What's already verified in this repo (CI-free, on a CommandLineTools Mac):**
> - `QuenderinKit` compiles in **all three** engine modes — mock, `QUENDERIN_LLAMA_DIR`
>   dev-build, and (config-wise) the xcframework path. (`swift build`)
> - Real llama.cpp inference runs end-to-end through `LlamaEngine`'s exact C-API path —
>   coherent output, ~135 tok/s decode (CPU, M-series Mac). (`apple/verify-llama-link.sh`)
> - The Xcode project generates cleanly from `project.yml` (`xcodegen`).
> - Android `quenderin-core` passes **99/99** checks (`kotlinc` + `java`).
>
> **What needs your machine (cannot be done from CommandLineTools alone):**
> - iOS: **full Xcode** (iOS SDK + Simulator) to build/run the app target; a physical
>   iPhone for real Metal tok/s, battery, and thermals.
> - Android: **Android SDK + Gradle** (mock APK) and additionally the **NDK** (native
>   llama build); an emulator or device to run.

---

## iOS

### Prereqs
- **Full Xcode** (not just CommandLineTools): `xcode-select -p` must point at
  `…/Xcode.app/Contents/Developer`. Switch with `sudo xcode-select -s /Applications/Xcode.app`.
- `brew install xcodegen`

### A. Bring-up (mock engine) — clickable app, no model
```bash
cd apple/QuenderinApp
xcodegen generate            # → Quenderin.xcodeproj (+ Info.plist, both git-ignored)
open Quenderin.xcodeproj     # then Run (⌘R) on an iPhone 16 simulator
```
The app boots into onboarding and runs the full flow on `MockInferenceEngine`. The engine
is chosen by `DefaultInferenceEngine.make()` — it's the mock until llama.cpp is linked (next).

### B. Real on-device inference — Route A, the shippable path
```bash
# 1. Build the llama.cpp xcframework (device + simulator + macOS slices; needs Xcode)
git clone https://github.com/ggml-org/llama.cpp && cd llama.cpp
./build-xcframework.sh        # → build-apple/llama.xcframework

# 2. Drop it into the package — Package.swift auto-detects it (no edits needed)
mkdir -p ../apple/QuenderinKit/Frameworks
cp -R build-apple/llama.xcframework ../apple/QuenderinKit/Frameworks/

# 3. Regenerate + run — canImport(llama) is now true, Metal GPU included
cd ../apple/QuenderinApp && xcodegen generate && open Quenderin.xcodeproj
```
`Frameworks/*.xcframework` is git-ignored (large binary — ship via Git LFS or a CI step).

> **Faster local check without the xcframework** (macOS only, Route C): point the package at
> a dev build of llama.cpp — see `apple/QuenderinKit/INTEGRATION.md` and `apple/verify-llama-link.sh`.

### Bigger models (optional)
To hold 4B+ comfortably before iOS *jetsam* kills the app, add the
`com.apple.developer.kernel.increased-memory-limit` entitlement (needs a provisioning
profile that allows it). Not required for bring-up or for 1–3B models.

---

## Android

### Prereqs
- **Android Studio** (or the command-line SDK) with **platform 35** + **build-tools 35**.
- For real inference only: the **NDK** (`sdkmanager "ndk;26.3.11579264"`) + CMake.
- Gradle 8.7–8.9 (matches AGP 8.5.2) — Android Studio bundles a compatible one.

### A. Bring-up (mock engine) — clickable app, no model, no NDK
The app is written to boot on `MockInferenceEngine` the moment it opens:
```bash
cd android
# In Android Studio: open the android/ folder, let it sync, Run on an emulator/device.
# Or headless (with a configured SDK + Gradle):
gradle :app:assembleDebug      # → app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
`MainActivity` already uses the **real** `WorkManagerModelDownloader`, and selects the
engine with `if (LlamaEngine.NATIVE_AVAILABLE) LlamaEngine() else MockInferenceEngine()` —
so it stays on the mock until the native `.so` is present (next).

### B. Real on-device inference — build the JNI bridge against llama.cpp
```bash
# 1. Add llama.cpp where the JNI CMake expects it (or pass -DLLAMA_DIR=…)
git submodule add https://github.com/ggml-org/llama.cpp android/jni/llama.cpp

# 2. In android/app/build.gradle.kts, uncomment:
#      ndk { abiFilters += listOf("arm64-v8a") }   // + "x86_64" for the emulator
#      externalNativeBuild { cmake { path = file("../jni/CMakeLists.txt"); version = "3.22.1" } }

# 3. Build — produces libquenderin_llama.so, flipping LlamaEngine.NATIVE_AVAILABLE true
gradle :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
See `android/INTEGRATION.md` for the JNI details. The native build is CPU (GGML_OPENMP off);
GPU/NNAPI deltas mainly affect prefill (decode is memory-bandwidth bound — see `apple/REALITY.md`).

---

## After it runs on a real phone
Replace the interpolated chip-score estimates with ground truth: capture decode tok/s,
post-throttle steady-state, and battery drain on physical A15/A17/A18 + a Snapdragon
flagship, then update the calibration tables (`apple/REALITY.md` documents the method).
