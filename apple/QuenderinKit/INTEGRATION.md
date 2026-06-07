# Linking llama.cpp into QuenderinKit

`LlamaEngine.swift` already contains the full inference path, gated behind
`#if canImport(llama)`. It compiles to a clean "not linked" fallback until an
importable module named **`llama`** exists. This guide gives that module two
ways: a quick SwiftPM dependency (best for a macOS smoke test) and a prebuilt
xcframework (best for the real iOS app, with Metal GPU).

> **The one rule:** the module must be named `llama` — that's what
> `LlamaEngine.swift` does `import llama`. Both routes below produce that name.

---

## Route 1 — SwiftPM dependency (fastest to try)

llama.cpp ships its own `Package.swift` exposing a `llama` library product, so a
dependency is all you need.

**Edit `apple/QuenderinKit/Package.swift`:**

```diff
 let package = Package(
     name: "QuenderinKit",
     platforms: [
         .iOS(.v16),
         .macOS(.v13),
     ],
     products: [
         .library(name: "QuenderinKit", targets: ["QuenderinKit"]),
     ],
+    dependencies: [
+        // Pin an exact tag for reproducibility — llama.cpp uses build-number
+        // tags like b4000. Bump deliberately; the C API drifts between tags.
+        .package(url: "https://github.com/ggml-org/llama.cpp", exact: "b4000"),
+    ],
     targets: [
-        .target(name: "QuenderinKit"),
+        .target(
+            name: "QuenderinKit",
+            dependencies: [.product(name: "llama", package: "llama.cpp")]
+        ),
         .testTarget(name: "QuenderinKitTests", dependencies: ["QuenderinKit"]),
     ]
 )
```

**Then:**

```bash
cd apple/QuenderinKit
swift build          # fetches + compiles llama.cpp; canImport(llama) → true
swift test           # the real C path now compiles and is type-checked
```

- 👍 One file changed, no manual build steps.
- 👎 Heavy C++ compile. The SwiftPM package often builds **Metal disabled /
  limited** — fine for proving it works on macOS, not for iOS GPU performance.
  For that, use Route 2.

---

## Route 2 — Prebuilt xcframework (recommended for the iOS app + Metal)

**1. Build the framework** (one-time, ~minutes):

```bash
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
git checkout b4000                 # match the tag you pin elsewhere
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

**4. Build:**

```bash
cd apple/QuenderinKit && swift build      # canImport(llama) → true, Metal included
```

- 👍 Metal GPU support — the perf you went native for. Fast, clean builds.
- 👎 One manual build step; the `.xcframework` is large (gitignored / Git LFS).

---

## After linking (either route)

### 1. Fix C-API signature drift
The `#if canImport(llama)` block in `LlamaEngine.swift` compiles for the first
time. The calls target the **late-2024/2025** API; if your pinned tag differs you
may see a handful of errors. The usual renames (already noted in code comments):

| If the compiler complains about… | Older/newer name |
|---|---|
| `llama_model_load_from_file` | older: `llama_load_model_from_file` |
| `llama_init_from_model` | older: `llama_new_context_with_model` |
| `llama_model_get_vocab` / vocab-based calls | older: tokenize/`token_to_piece` took the **model**, not a `vocab` |
| `llama_sampler_*` chain | very old builds used `llama_sample_*` |

Paste the errors and they're a quick fix against your tag.

### 2. Get a model onto the device
`OnboardingModel` downloads to `ApplicationSupport/Quenderin/models/<filename>`.
Start with the smallest catalog entry — **`llama32-1b-q2`, 0.4 GB**
(`llama-3.2-1b-instruct.Q2_K.gguf`). Either let the app download it via
`URLSessionModelDownloader`, or side-load it into the simulator's container for a
fast first run.

### 3. Flip the app to real
In `apple/QuenderinApp/Sources/QuenderinApp.swift`, swap the two `init()` lines:

```diff
-        let engine: InferenceEngine = MockInferenceEngine()
-        let downloader: ModelDownloader = MockModelDownloader()
+        let engine: InferenceEngine = LlamaEngine()
+        let downloader: ModelDownloader = URLSessionModelDownloader()
```

Run on a simulator/device → onboarding downloads + loads the GGUF, chat streams
**real** tokens.

### 4. (Optional) Prove it headlessly first
With Route 1 on macOS you can write a one-off integration test (not committed —
it needs a real model file):

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

- **`no such module 'llama'`** — the dependency/binary target isn't wired into
  the `QuenderinKit` target's `dependencies`. Re-check the Package.swift diff.
- **Linker errors about `ggml_*`** — llama.cpp depends on ggml; the xcframework
  bundles it. If using a hand-built static lib, link ggml too. The official
  xcframework and the SwiftPM package both handle this for you.
- **Metal shader / "default.metallib not found" at runtime** — use the
  xcframework (Route 2); it embeds the Metal library. The bare SwiftPM package
  may not.
- **App Store / code signing** — a `.binaryTarget` xcframework links fine; make
  sure it's an xcframework (multi-slice), not a bare `.framework`.
- **Slow `swift build` (Route 1)** — expected; it's compiling llama.cpp's C++.
  Subsequent builds are cached.

---

## Why `main` stays green without this

`LlamaEngine.swift` keeps every real call inside `#if canImport(llama)`. With no
`llama` module, that code is skipped and the engine returns a clean
`.loadFailed` (verified by `LlamaEngineTests`). So the package builds and all 40
tests pass **before** you do any of the above — and the app runs on
`MockInferenceEngine` meanwhile.
