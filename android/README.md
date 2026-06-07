# Quenderin for Android

Native Android client. Same architecture as iOS: a portable, tested **brain** in pure
Kotlin, a thin **JNI adapter** to llama.cpp, and a **Compose UI** — built so everything
that can be proven without a device is proven, and the rest is a clearly-marked cliff.

## Layout

```
android/
├── quenderin-core/      Pure-Kotlin/JVM brain — NO Android deps. The source of truth.
│   ├── ModelCatalog · ModelRecommender · MemoryFitness · SafetyBlocklist
│   ├── InferenceEngine (seam) · MockInferenceEngine · LlamaEngine (JNI adapter)
│   ├── ModelDownloader (seam) · MockModelDownloader
│   ├── OnboardingModel (M1 state machine) · ChatModel (M2)
│   ├── src/verify/CoreVerify.kt   ← headless harness (kotlinc + java, 29 checks)
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

## Go real

Linking llama.cpp (NDK + CMake) and running on a device is the on-device cliff —
see **`INTEGRATION.md`**. `MainActivity` auto-switches to the real engine once the
native `.so` is built; no code change required.

## Parity rule

`ModelCatalog` + `ModelRecommender` must stay identical across desktop (`src/constants.ts`),
iOS (`apple/QuenderinKit`), and here. Today they're hand-synced; the plan is to have the
desktop emit a shared manifest JSON the mobile clients consume.
