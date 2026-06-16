# Physical-device verification runbook

Everything else is automated, simulated, or unit-tested. This is the one thing that
**requires you and a physical phone**: ground-truth numbers that a Mac, an iOS Simulator,
or an Android emulator physically cannot produce —

- **real on-device tok/s** (Metal on Apple GPUs, the actual SoC on Android — not a host-CPU ceiling),
- **battery drain** under a sustained agent loop (`%/hr`),
- **thermal throttling** (STATUS.md flags heat, not memory, as the agent-loop ceiling).

The inference path itself is already proven on both platforms (simulator/emulator, real
llama.cpp). What's missing is replacing the conservative, clearly-labelled chip-score
*estimates* in `apple/REALITY.md` with measured truth. Fill in the [results table](#results)
at the bottom and update `apple/REALITY.md` if reality differs.

> **Why this can't be automated here:** it needs hardware physically attached to a machine,
> plus (iOS) a signing identity. Steps below are copy-pasteable; the judgement calls
> (which device, acceptable thermals) are yours.

---

## iOS (physical iPhone)

**You need:** a physical iPhone, a Mac with Xcode 16+, and an Apple ID (a *free* one gives
7-day development provisioning — no paid Developer Program required just to run on your own
device; you only need the paid program to ship — see `STORE_SUBMISSION.md`).

1. **Build the real-inference framework** so a device build links llama.cpp (Metal) without
   `QUENDERIN_LLAMA_DIR`:
   ```sh
   apple/build-xcframework.sh           # ~20–60 min first run; writes apple/QuenderinKit/Frameworks/llama.xcframework
   ```
2. **Generate + open the app project:**
   ```sh
   cd apple/QuenderinApp && xcodegen generate   # project.yml → Quenderin.xcodeproj (bundle prefix ai.quenderin)
   open Quenderin.xcodeproj
   ```
3. **Sign it:** select the app target → *Signing & Capabilities* → pick your Team. (Free Apple
   ID is fine; Xcode provisions automatically.)
4. **Run on device:** plug in the iPhone, choose it as the run destination, ⌘R. Trust the
   developer profile on the phone if prompted (Settings → General → VPN & Device Management).
5. **Exercise the real path:** onboard → accept the recommended model → download over Wi-Fi
   (it will run the C3 integrity check after download) → send a few chat turns → run an agent
   loop for **5–10 minutes** to surface sustained throttling.
6. **Capture numbers:**
   - **tok/s** — the engine logs prompt + decode tok/s; or read the in-app metrics.
   - **battery** — Settings → Battery (per-app %), or Xcode → Debug navigator → Energy gauge.
   - **thermals** — the app reads `ProcessInfo.processInfo.thermalState`; watch for
     `.serious` / `.critical` during the sustained loop. Note the model + minutes-to-throttle.

---

## Android (physical phone)

**You need:** a physical Android phone with USB debugging on, Android Studio / SDK + NDK, and
`android/jni/llama.cpp` present (so the real `libquenderin_llama.so` is bundled — see
`android/verify-llama-link.sh`, which already clones/builds it).

1. **Build a real-inference APK** (jni/llama.cpp present → auto-bundles the native lib):
   ```sh
   cd android && ./gradlew :app:assembleDebug
   ```
2. **Install + launch:**
   ```sh
   adb install -r app/build/outputs/apk/debug/app-debug.apk
   adb shell monkey -p ai.quenderin.app 1
   ```
3. **Confirm the real engine loaded** (not the mock):
   ```sh
   adb logcat | grep -iE "nativeloader|quenderin_llama|NATIVE_AVAILABLE"   # expect "...ok"
   ```
4. **Exercise the path:** onboard → download → chat → run an agent loop 5–10 min.
5. **Capture numbers:**
   - **tok/s** — logcat (the engine logs decode rate). For a clean isolated number,
     `android/verify-llama-link.sh` runs raw inference (currently targets an emulator — point
     `adb` at the device / pass the serial to get device numbers).
   - **battery** — `adb shell dumpsys batterystats --charged ai.quenderin.app` (or Battery Historian).
   - **thermals** — `adb shell dumpsys thermalservice` (watch the throttling status during the loop).

---

## Results

Fill this in per device; then reconcile `apple/REALITY.md` (iOS) / the Android SoC scores in
`AndroidSoc` if measured numbers diverge from the estimates.

| Device | SoC / chip | Model (id) | Prompt tok/s | Decode tok/s | Battery %/hr (agent loop) | Peak thermal state | Mins to throttle |
|--------|-----------|------------|-------------:|-------------:|--------------------------:|--------------------|------------------|
| _e.g. iPhone 16 Pro_ | A18 Pro | qwen3-4b | | | | | |
| _e.g. Pixel 9 Pro_ | Tensor G4 | qwen3-4b | | | | | |
| | | | | | | | |

**Pass criteria (suggested):** decode tok/s usable for chat (≳10), agent loop sustainable
without hitting `.critical` thermal in the first ~10 min, battery drain disclosed to users.
Record whatever you see — even "throttles in 4 min" is a shippable finding (it informs the
default model pick and the heat warning the picker already surfaces).
