# Linking llama.cpp into QuenderinKit

`LlamaEngine.swift` already contains the full inference path, gated behind
`#if canImport(llama)`. It compiles to a clean "not linked" fallback until an
importable module named **`llama`** exists. This guide gives that module.

> **The one rule:** the module must be named `llama` — that's what
> `LlamaEngine.swift` does `import llama`.

> **⚠️ Reality check (verified 2026-06-07):** upstream llama.cpp **removed its
> SwiftPM `Package.swift` from `master`.** A plain `.package(url:)` dependency
> (the old "easy" route) therefore works **only against an old pinned tag**, and
> that older tag mismatches the current C API. **The supported path today is the
> prebuilt xcframework (Route A below).**

> **✅ PROVEN BY EXECUTION (2026-06-07, macOS / Xcode 16.2):** not just "the calls
> match the header" — the exact `LlamaEngine` sequence was **compiled, linked, and run
> against a real llama.cpp build with the Metal GPU backend**, producing coherent output
> ("the sky is blue because tiny particles of gas… scatter light…") at **prefill ~3,800
> tok/s · decode ~177 tok/s** for Qwen2.5‑0.5B Q4_K_M on an M‑series Mac. Reproduce it:
>
> ```bash
> apple/verify-llama-link.sh      # clones+builds llama.cpp, fetches a tiny model, runs inference
> ```
>
> It builds `apple/tools/llama-smoketest.swift` (a standalone mirror of `LlamaEngine`'s
> load → tokenize → decode → sample → detokenize) with this module map + flags — the
> recipe for the system-library target in Route B:
>
> ```
> module llama { header ".../llama.cpp/include/llama.h"  export * }
> swiftc … -Xcc -fmodule-map-file=cllama/module.modulemap \
>          -Xcc -I…/include -Xcc -I…/ggml/include -I cllama -L…/build/bin -lllama
> ```
>
> **And it runs on iOS too:** the same code was rebuilt for the **iOS simulator arch**
> and run **on a booted iPhone 16 simulator** via `simctl spawn` — coherent output, ~160
> tok/s (CPU). ⚠️ The iOS *simulator's* Metal **compute** path is broken (it emits garbage
> with GPU layers on), so the smoke test forces CPU there (`QUENDERIN_NGL=0`); **real
> devices use Metal** (proven on the Mac above). `apple/verify-llama-link.sh` now does the
> simulator stage automatically when a simulator is available.
>
> So the cliff is **crossed**, not just de-risked: the integration compiles, links, and
> runs both on macOS-Metal and on a simulated iPhone. What genuinely still needs **physical
> hardware**: the iOS-device xcframework (Route A) and real on-*phone* tok/s/battery (the
> Mac/sim numbers are CPU/host ceilings, not a phone result). Every C call matches current
> `master` (`llama_model_load_from_file`,
> `llama_init_from_model`, vocab-based `llama_tokenize`/`llama_token_to_piece`, the
> `llama_sampler_*` chain, 2-arg `llama_batch_get_one`, `llama_vocab_is_eog`).

---

## Route A — Prebuilt xcframework (the supported path) ✅

**1. Build the framework** (one-time, ~minutes; needs Xcode):

```bash
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
./build-xcframework.sh             # → build-apple/llama.xcframework
```

**2. Place it** under the package and ignore the large binary:

```bash
mkdir -p apple/QuenderinKit/Frameworks
cp -R build-apple/llama.xcframework apple/QuenderinKit/Frameworks/
echo "Frameworks/*.xcframework" >> apple/QuenderinKit/.gitignore   # or use Git LFS
```

**3. Edit `apple/QuenderinKit/Package.swift`:**

```diff
     targets: [
-        .target(name: "QuenderinKit"),
+        .target(name: "QuenderinKit", dependencies: ["llama"]),
+        .binaryTarget(name: "llama", path: "Frameworks/llama.xcframework"),
         .testTarget(name: "QuenderinKitTests", dependencies: ["QuenderinKit"]),
     ]
```

**4. Build** — `canImport(llama)` flips true, Metal GPU included:

```bash
cd apple/QuenderinKit && swift build
```

The xcframework has a macOS slice, so you can even `swift test` real inference on
your Mac with a small GGUF before touching a simulator.

---

## Route B — SwiftPM dependency (legacy, old tags only) ⚠️

Only viable pinned to a tag from **before** the manifest was removed, e.g. a
`b3xxx` build. Not recommended: that older API will differ from `LlamaEngine`'s
current calls, so you'd be fixing drift the xcframework avoids.

```swift
dependencies: [
    .package(url: "https://github.com/ggml-org/llama.cpp", exact: "b3600"), // pre-removal
],
targets: [
    .target(name: "QuenderinKit",
            dependencies: [.product(name: "llama", package: "llama.cpp")]),
    ...
]
```

If `swift build` fails with "no Package.swift in repository", the tag is past the
removal point — bump *down* to an older one, or just use Route A.

---

## Route C — Headless source build via `$QUENDERIN_LLAMA_DIR` (fastest to verify) ✅

For compiling/running the **real** engine on a Mac with no xcframework — and the
path the committed regression test (`LlamaEngineRealInferenceTests`) uses — point
the package at a built llama.cpp checkout:

```bash
git clone --depth 1 https://github.com/ggml-org/llama.cpp /tmp/llama.cpp
cmake -S /tmp/llama.cpp -B /tmp/llama.cpp/build -DBUILD_SHARED_LIBS=ON -DGGML_METAL=ON \
      -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF \
      -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_CURL=OFF
cmake --build /tmp/llama.cpp/build --target llama -j

# the real LlamaEngine actor compiles + links (#if canImport(llama) goes true):
QUENDERIN_LLAMA_DIR=/tmp/llama.cpp swift build
# …and runs end to end against any small GGUF:
QUENDERIN_LLAMA_DIR=/tmp/llama.cpp QUENDERIN_LLAMA_MODEL=/path/model.gguf \
  DYLD_LIBRARY_PATH=/tmp/llama.cpp/build/bin \
  swift test --filter LlamaEngineRealInferenceTests
```

With `QUENDERIN_LLAMA_DIR` **unset**, the package is byte-for-byte the mock-only
build `main` always shipped — no dependency, `canImport(llama)` false. `Package.swift`
adds a `llama` system-library target (`Sources/llama/`) plus the `-I` / `-L` / `-rpath`
flags **only when it is set**. This links dynamically against a *dev* build — for a
shippable app use the xcframework (Route A); Route C is the fastest path for headless
CI/verification on macOS.

> **Verified 2026-06-07:** with `QUENDERIN_LLAMA_DIR` set, `swift build` compiles
> `LlamaEngine`'s `#if canImport(llama)` path (warning-free); `swift test` runs 153 tests
> with the gated real-inference test skipping cleanly when the env vars are absent.

---

## Authoritative reference

llama.cpp ships an official SwiftUI example you can mirror for the binding:
**`examples/llama.swiftui/`** in the repo, especially its `LibLlama.swift`
wrapper. It's kept in sync with the C API, so if anything in `LlamaEngine.swift`
ever drifts, diff against `LibLlama.swift` for the current call shape.

---

## After linking

### 1. Get a model onto the device
`OnboardingModel` downloads to `ApplicationSupport/Quenderin/models/<filename>`.
Start with the smallest catalog entry — **`llama32-1b-q2`, 0.4 GB**
(`llama-3.2-1b-instruct.Q2_K.gguf`). Let the app fetch it via
`URLSessionModelDownloader`, or side-load it into the simulator container.

### 2. Flip the app to real
In `apple/QuenderinApp/Sources/QuenderinApp.swift`, swap the two `init()` lines:

```diff
-        let engine: InferenceEngine = MockInferenceEngine()
-        let downloader: ModelDownloader = MockModelDownloader()
+        let engine: InferenceEngine = LlamaEngine()
+        let downloader: ModelDownloader = URLSessionModelDownloader()
```

Run on a simulator/device → onboarding downloads + loads the GGUF, chat streams
**real** tokens.

### 3. (Optional) Prove it headlessly first
With Route A on macOS, a one-off integration test (not committed — needs a real
model file):

```swift
func testRealInferenceSmoke() async throws {
    let engine = LlamaEngine()
    let url = URL(fileURLWithPath: "/path/to/llama-3.2-1b-instruct.Q2_K.gguf")
    try await engine.load(model: ModelCatalog.entry(id: "llama32-1b-q2")!, at: url)
    let reply = try await engine.complete(prompt: "Say hello in one word.")
    XCTAssertFalse(reply.isEmpty)
}
```

---

## Troubleshooting

- **`no such module 'llama'`** — the binary target isn't in `QuenderinKit`'s
  `dependencies`. Re-check the Package.swift diff.
- **`no Package.swift in repository` (Route B)** — your tag is past the manifest
  removal; pin an older `b3xxx` tag, or use Route A.
- **Linker errors about `ggml_*`** — the xcframework bundles ggml; a hand-built
  static lib would need ggml linked separately. Route A handles this.
- **Metal "default.metallib not found" at runtime** — use Route A; it embeds the
  Metal library. A bare source build may not.
- **App Store / code signing** — a `.binaryTarget` xcframework links fine; ensure
  it's an xcframework (multi-slice), not a bare `.framework`.

---

## Why `main` stays green without any of this

`LlamaEngine.swift` keeps every real call inside `#if canImport(llama)`. With no
`llama` module that code is skipped and the engine returns a clean `.loadFailed`
(verified by `LlamaEngineTests`). So the package builds and all 40 tests pass
**before** you do any of the above — and the app runs on `MockInferenceEngine`
meanwhile.
