# Bonsai 2 27B integration

The `bonsai2-27b` catalog entry is an experimental manual choice. It pins PrismML's
PTQ1_0 language weights to a Hugging Face revision and SHA-256, with an exact
5,946,648,928-byte download. The separate vision projector is not integrated.
Existing defaults remain unchanged. This does not claim store distribution or
measured Quenderin inference performance.

The source/runtime pins are in `shared/prism-runtime.json`. The custom ternary
types and Hadamard activation transforms require the Prism fork; ordinary GGUF
support is insufficient. Stock and older binaries reject download and loading.
The model has a conservative 7 GB footprint floor plus the usual 30% runtime
overhead (9.1 GB estimated working memory). Native fitness also retains its 85%
usable-budget gate, so a 9.1 GB app-memory budget is insufficient. Context is
capped at 4,096 tokens. Actual allocation still depends on the backend. A
compressed file fitting on disk does not prove RAM fit.

## Apple

App Store archives use the committed XcodeGen project and shared `Quenderin`
(iOS) and `QuenderinMac` schemes. Configure Xcode Cloud with the explicit
`QUENDERIN_RUNTIME=prism` environment variable and Archive actions for App Store
distribution. The post-clone hook builds the pinned iOS device and universal Mac
framework before package resolution. Later hooks validate the checkout through
`CI_PRIMARY_REPOSITORY_PATH` and reject missing release inputs.

The release profile forbids stock or mock fallback. The final Cloud hook verifies
the App Store signed export at `CI_APP_STORE_SIGNED_APP_PATH` (one iOS IPA, macOS
PKG, or app), because Cloud's intermediate archive may use ad-hoc signing. It checks
the embedded runtime, model catalog, version/build, team signature and native
ternary capability on Mac. Package extraction rejects unsafe paths, ambiguity and
oversized payloads, uses fresh scratch, and never runs an installer. The separate
`verify-archive` command still requires a signed archive. Mach-O section identity survives Xcode signing and
thinning; source framework files also have complete SHA-256 digests. Runtime
deployment minima are iOS 16.4 and macOS 13.3. Version 0.3.0 uses candidate build
12; the actual Xcode Cloud counter must be at least 12 before starting a build.

On 12 October 2026, Xcode Cloud build 15 from
`9bab8d8aa67f2ecfdeb93b7a88cc4aed59592568` passed both App Store archive actions,
signed-export verification and App Store Connect preparation. The iOS export is
arm64; macOS is universal arm64/x86_64. Both contain the pinned Prism revision.
The exact iOS and macOS **0.3.0 (15)** builds were then submitted to App Review
and show **Waiting for Review**, with automatic release after approval and
immediate rollout enabled. Approval and public availability are still pending.
The existing public Apple apps remain 0.2.0 until that release completes.
Both store drafts exist with automatic release after approval. Signed archives,
submission and public availability remain separate release gates.

After checking disk headroom with session-storage, build in a **new** work path:

```sh
apple/build-prism-xcframework.sh /absolute/new/prism-build
QUENDERIN_RUNTIME=prism swift test --package-path apple/QuenderinKit
```

The build installs `Frameworks/prism-llama.xcframework` alongside the existing
stock framework, without replacing it. Package.swift uses its provenance stamp
and the native type table; it selects the Prism framework automatically when
present. `QUENDERIN_RUNTIME=standard` selects the existing standard framework.
An explicit Prism source build uses `QUENDERIN_LLAMA_DIR` and takes precedence
over framework selection; source verification must pass first.

For source-linked `swift test`, pass the C include paths to every compiler
invocation, including SwiftPM's generated test-discovery targets:

```sh
QUENDERIN_RUNTIME=prism QUENDERIN_LLAMA_DIR=/absolute/new/prism-source \
  swift test --package-path apple/QuenderinKit \
    -Xcc -I/absolute/new/prism-source/include \
    -Xcc -I/absolute/new/prism-source/ggml/include
```

## Android

Prepare a new checkout, then point the existing app build at it:

```sh
python3 scripts/prepare_prism_runtime.py fetch --destination /absolute/new/prism-source
cd android
./gradlew :app:assembleDebug -Pquenderin.runtime=prism -Pquenderin.llamaDir=/absolute/new/prism-source
```

CMake verifies repository, exact revision, clean tracked source, custom types and
Hadamard loader before enabling the JNI capability. Old `.so` files without the
new capability symbol fail closed. Standard builds retain their existing path.

## Windows and Linux desktop

The pinned `node-llama-cpp` 3.19.1 addon requires the versioned C API patch in
`scripts/patches/node-llama-cpp-3.19.1-prism-e8fd209.json`. It maps model loading
options to Prism's load-mode enum, adapts the repetition and DRY samplers, and
allows the packaged loader to locate a verified build without a source checkout.
The patch checks complete official source hashes before changing any file,
and retains the originals. Do this in a fresh dependency installation after
checking disk headroom. Git, Python 3, Node.js 20+, CMake and the platform C++
toolchain must already be available (MSVC Build Tools on Windows).

```sh
python3 scripts/prepare_prism_node_runtime.py prepare --package-dir node_modules/node-llama-cpp
node node_modules/node-llama-cpp/dist/cli/cli.js source build --gpu false --ciMode --noUsageExample
python3 scripts/prepare_prism_node_runtime.py verify --package-dir node_modules/node-llama-cpp
```

The current desktop loader selects this deterministic CPU build. After building,
run `node scripts/verify_prism_node_runtime.mjs`. This loads the compiled addon
with builds, downloads and prebuilt fallback disabled; it verifies exact runtime
metadata and executes the native PQ2_0/PTQ1_0 block-size and packed-size exports.
It establishes native binding capability, not full-model generation quality.

On Windows, use the installed Python launcher (`py -3`) in place of `python3`.
The helper fetches the exact pinned runtime into the package's **new**
`llama/llama.cpp` checkout, then writes the official Node source metadata from
the verified repository/revision. It refuses an existing source checkout,
or backup directory; use a new build workspace if either exists. The official
3.19.1 package's stock `llama.cpp.info.json` is accepted only at its exact
published SHA-256 preimage, preserved in the backup, and patched to the verified
Prism pin. Changed, custom or symlinked metadata is rejected before fetching or
changing any file. A
repeated successful preparation verifies the same files without overwriting
them. Do not use `source download`: that upstream command removes an existing
checkout. A direct-I/O and memory-lock combination with mmap disabled is
rejected explicitly because Prism has no equivalent load mode.

Desktop packaging keeps `llama/localBuilds/**` (including its native addon and
build metadata), `llama/lastBuild.json`, `llama/llama.cpp.info.json`, and
`llama/quenderin-prism-node-runtime.json`. The source checkout and original-file
backup are build inputs and are excluded from release packages. The loader's
packaged path requires the exact preparation stamp and source metadata; it does
not alter standard, unstamped installations or authorize runtime compilation.

Quenderin probes an already-built local addon without downloading/building a
backend, and checks its reported repository and exact revision again before
loading. Catalog requests never compile a backend. A missing compatible addon
leaves Bonsai blocked with a runtime message. Electron release packaging must
carry that custom addon; a stock prebuilt does not establish support.

## Verification and release status

[Desktop release v0.2.1](https://github.com/alikatgh/quenderin/releases/tag/v0.2.1)
publishes Windows and Linux installers from commit
`156b150f0f48ec0fdc17c7cb94124d755d18be6f`.
[Release run 38204274341](https://github.com/alikatgh/quenderin/actions/runs/38204274341)
passed packaged native-addon checks on both platforms and exact-model generation
through the packaged Linux runtime, which returned `hello` with a 512-token
context. All four installer assets passed upload/provenance checks before
publication. [CI 38204269190](https://github.com/alikatgh/quenderin/actions/runs/38204269190)
also passed all jobs on that source revision. Native store updates remain separate.

Run the normal catalog and model suites plus:

```sh
python3 -m unittest discover -s scripts/tests -p test_prism_runtime.py
python3 -m unittest discover -s scripts/tests -p test_prism_node_runtime.py
python3 -m unittest discover -s scripts/tests -p test_prism_apple_runtime.py
python3 scripts/check_catalog_parity.py
node --test scripts/tests/model-releases.test.mjs
```

Hosted CI run [38201154541](https://github.com/alikatgh/quenderin/actions/runs/38201154541)
built the pinned Prism CPU runtime, downloaded and SHA-256 verified the exact
catalog artifact, and loaded it to generate `hello` on 12 October 2026. This is a
bounded runtime check, not a Quenderin performance benchmark. Both Windows and
Linux packaged Electron apps passed the native addon probe, and the actual Prism
Android APK build and unit tests passed. Run
[38201651569](https://github.com/alikatgh/quenderin/actions/runs/38201651569)
also passed 553 tests against the source-linked Prism Swift adapter (nine skipped,
zero failures). The desktop release additionally requires full-model generation
through the packaged addon. Signed Apple 0.3.0 (15) artifacts have now been
uploaded and submitted as recorded above; public Apple availability is pending.
Physical-phone testing was waived for this change. Local full builds and the
5.95 GB model download were blocked by disk capacity, so those checks run on
hosted runners. Blog publication, source publication, native binaries and store
availability are separate states.

Desktop installers are uploaded directly to a draft GitHub Release after their
checks. Publication requires both platform builds, exact tag/source provenance,
and all four expected installer assets. Existing assets are never overwritten.
This path avoids metered Actions artifact storage; standard public-repository
runners and GitHub Release distribution use the existing included service. See
[Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
and [Release limits](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).
Partial uploads can resume only when an existing installer's size and SHA-256
match the local build. An incomplete asset, missing digest, or different rebuild
stops publication. Keep that draft and its files; use a new version for a changed
build instead of replacing assets or moving the old tag.

Audit status on 12 October 2026: the required root `npm audit --audit-level=high`
gate passes after scoped transitive dependency fixes, with no high or critical
findings. Moderate Electron build-tool findings and pre-existing findings in the
separate UI build dependency tree remain; this is not a full security clearance.

Sources: [official model card](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf),
[Prism fork](https://github.com/PrismML-Eng/llama.cpp/tree/e8fd209c975c80aa7fb36a8423571ff3b1b7e955).
