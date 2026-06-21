# Quenderin for Android

Native Android client. Same architecture as iOS: a portable, tested **brain** in pure
Kotlin, a thin **JNI adapter** to llama.cpp, and a **Compose UI** — built so everything
that can be proven without a device is proven, and the rest is a clearly-marked cliff.

## Layout

```
android/
├── quenderin-core/      Pure-Kotlin/JVM brain — NO Android deps. The source of truth.
│   ├── ModelCatalog · ModelRecommender · MemoryFitness · SafetyBlocklist
│   ├── AndroidSoc · AndroidDeviceProfile · AndroidModelSelector · ThermalBattery
│   │      ↳ device-aware picker (native-heap budget + chip + disk + heat/battery),
│   │        twin of iOS IPhoneModelSelector — unlocks 7B on 12–16 GB flagships
│   ├── InferenceEngine (seam) · MockInferenceEngine · LlamaEngine (JNI adapter)
│   ├── ModelDownloader (seam) · MockModelDownloader
│   ├── DownloadPolicy · DiskSpace · OfflineReadiness · DownloadStore  (M3 offline + resume)
│   ├── AgentTool · AgentDecision · AgentLoop · ScriptedInferenceEngine  (M4 agent loop)
│   ├── OnboardingModel (M1 state machine) · ChatModel (M2)
│   ├── src/verify/CoreVerify.kt   ← headless harness (kotlinc + java, 139 checks)
│   └── src/test/…/CoreTest.kt     ← JUnit mirror (./gradlew test)
├── jni/                 C++ bridge to llama.cpp (llama_jni.cpp + CMakeLists.txt)
└── app/                 Jetpack Compose app over the core (MainActivity + ui/)
```

## Verify the brain headlessly (no Gradle/Android needed)

```sh
KOTLINC="/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc/bin/kotlinc"
cd android/quenderin-core
bash "$KOTLINC" src/main/kotlin/ai/quenderin/core/*.kt src/verify/CoreVerify.kt \
    -include-runtime -d /tmp/qcore.jar && java -jar /tmp/qcore.jar    # → ALL PASSED
```

This is the Android equivalent of `swift test` for `apple/QuenderinKit`. It proves the
catalog + recommendation match the other platforms, memory fitness, the safety
blocklist, the `LlamaEngine` off-device fallback, and the M1/M2 onboarding + chat flows.

## Run the app (mock engine)

Open `android/` in Android Studio → run `app`. The full onboarding → chat flow works on
`MockInferenceEngine`; no llama.cpp required.

## What the selector picks (and why Android differs from iOS)

`AndroidModelSelector` gates each model on memory + chip speed + disk, then defaults to
the largest *comfortable* model. Android's memory reality differs from iOS, and the picks
show it:

| Device | Pick | Why |
|--------|------|-----|
| 4 GB mid-range | Llama 3.2 1B | budget ~2.2 GB; 3B too big |
| 6 GB Snapdragon 8 Gen 2 | Qwen3 4B | the mainstream sweet spot |
| 8 GB Snapdragon 8 Gen 3 | Qwen3 4B | comfortable; 7B *offered* (tight) |
| 12 GB + slower chip | Qwen3 4B | RAM allows more, but the chip is the limit |
| **16 GB Snapdragon 8 Elite** | **Mistral 7B** | RAM + a fast chip unlock a 7B **no 8 GB iPhone can hold** |

Two Android-specific truths, both from the measured research (`apple/REALITY.md`):
- **Native heap, not jetsam.** llama.cpp allocates via JNI on the native heap, which is
  bounded by total RAM + the low-memory-killer — *not* the tiny Dalvik per-app cap. So
  budgets are more generous than iOS, and the 12–16 GB tiers (common on Android) unlock
  bigger models.
- **The 7 tok/s floor keeps 14B off phones** — it's too slow to feel alive even at 16 GB.

`ThermalBattery` attaches the same heat/battery advisory as iOS.

## Go real

Linking llama.cpp (NDK + CMake) and running on a device is the on-device cliff —
see **`INTEGRATION.md`**. `MainActivity` auto-switches to the real engine once the
native `.so` is built; no code change required.

## Parity rule

`ModelCatalog` + `ModelRecommender` must stay identical across desktop (`src/constants.ts`),
iOS (`apple/QuenderinKit`), and here — enforced by `scripts/check_catalog_parity.py`
(`npm run check:catalog-parity`). The selectors (`AndroidModelSelector` /
`IPhoneModelSelector`) are platform-specific by design; the *catalog* is the shared part.
