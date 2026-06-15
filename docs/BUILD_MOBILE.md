# Building & running the native apps (iOS + Android)

How to take the Swift (`apple/`) and Kotlin (`android/`) apps from source to a running
install. Two tiers per platform:

- **Bring-up (mock engine)** — the whole UI flow (onboarding → chat → agent) runs with no
  model file. Fastest way to see the app on a device/simulator.
- **Real on-device inference** — link llama.cpp so the app actually generates tokens.

> **What's verified end-to-end in this repo (2026-06-14, no CI):**
> - **iOS app builds + runs** on the iPhone 17 simulator (Xcode 26.3): `xcodegen` →
>   `xcodebuild -sdk iphonesimulator` → install + launch; the model picker renders a
>   device-aware recommendation (Apple M4 → Llama 3.2 3B Balanced).
> - **Android app builds + runs** on a booted arm64 emulator: `./gradlew :app:assembleDebug`
>   → `adb install` → launch; picker renders (low-mem emulator → Llama 3.2 1B).
> - **Real llama.cpp inference runs on both:** iOS `apple/verify-llama-link.sh` (~135 tok/s,
>   CPU, Mac) and Android `android/verify-llama-link.sh` **on the emulator** (~102 tok/s, CPU,
>   arm64). The real-inference Android APK loads `libquenderin_llama.so` (`NATIVE_AVAILABLE`
>   true). `QuenderinKit` compiles in all engine modes (`swift build`); Android core 99/99.
>
> **What still needs a physical device (ground-truth numbers only — the path is proven):**
> - A real **iPhone** for Metal tok/s + battery + thermals, and a real **Android phone** for
>   SoC tok/s. The Mac/sim/emulator numbers are host-CPU ceilings.

---

## iOS

### Prereqs
- **Full Xcode** (not just CommandLineTools): `xcode-select -p` must point at
  `…/Xcode.app/Contents/Developer`. Switch with `sudo xcode-select -s /Applications/Xcode.app`.
- `brew install xcodegen`

### A. Bring-up (mock engine) — clickable app, no model ✅ verified
```bash
cd apple/QuenderinApp
xcodegen generate            # → Quenderin.xcodeproj (+ Info.plist, both git-ignored)
open Quenderin.xcodeproj     # then Run (⌘R) on an iPhone simulator
# …or fully headless (what was verified here):
xcodebuild -project Quenderin.xcodeproj -scheme Quenderin -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
xcrun simctl install booted "$(find ~/Library/Developer/Xcode/DerivedData -name Quenderin.app -path '*iphonesimulator*' | head -1)"
xcrun simctl launch booted ai.quenderin.Quenderin
```
The app runs the full flow on `MockInferenceEngine`. The engine is chosen by
`DefaultInferenceEngine.make()` — mock until llama.cpp is linked (next).

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
- A committed Gradle **wrapper** (`./gradlew`, pinned to 8.9 to match AGP 8.5.2) — no
  separate Gradle install needed. JDK **17** for the build (`JAVA_HOME=…/openjdk@17`).
- `android/local.properties` with `sdk.dir=<your Android SDK>` (git-ignored).

### A. Bring-up (mock engine) — clickable app, no model, no NDK ✅ verified
The app boots on `MockInferenceEngine` the moment it opens. **This build is verified in-repo**
— produces `app-debug.apk` (`ai.quenderin.app`, label "Quenderin", target SDK 35):
```bash
cd android
echo "sdk.dir=$ANDROID_SDK_ROOT" > local.properties     # one-time
JAVA_HOME=$(/usr/libexec/java_home -v 17) ./gradlew :app:assembleDebug
#   → app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/debug/app-debug.apk  # to a device/emulator
# (Or just open the android/ folder in Android Studio and hit Run.)
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
JAVA_HOME=$(/usr/libexec/java_home -v 17) ./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
See `android/INTEGRATION.md` for the JNI details. The native build is CPU (GGML_OPENMP off);
GPU/NNAPI deltas mainly affect prefill (decode is memory-bandwidth bound — see `apple/REALITY.md`).

---

## After it runs on a real phone
Replace the interpolated chip-score estimates with ground truth: capture decode tok/s,
post-throttle steady-state, and battery drain on physical A15/A17/A18 + a Snapdragon
flagship, then update the calibration tables (`apple/REALITY.md` documents the method).
