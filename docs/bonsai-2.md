# Bonsai 2 27B integration

## 18 October 2026 engineering candidate

The current candidate extends the pinned Prism runtime rather than treating a
catalog row as model support. The normal catalog has 28 entries in matching
TypeScript, Swift and Kotlin manifests. The new text paths include the smaller
Bonsai 2 models, LFM2.5-24B-A2B, Jais 3, Nemotron 3.5 Bolt, complete Beam and
complete Muse on native Apple, Android and desktop. Publisher text protocols
have dedicated adapters; tool use is disabled for the experimental Beam/Muse
chat paths. Model-weight inference for
these additions has **not** been run. This section describes engineering in the
candidate, not a new public installer or store release.

Beam's four-part download is **133,885,310,500 bytes**, including its 5,954,020-byte
metadata entry point. All four parts are required. Its minimum whole-model
memory floor is 160 GiB before context overhead. Muse requires all 22 Q2_K parts,
304,080,474,208 bytes. The desktop adapter now accompanies the native adapters;
the older October 16 snapshot below records the earlier scope. Complete hashes,
compiled architecture capabilities and actual free-memory checks gate loading.
Active parameter counts do not reduce the storage or full-weight memory budget.

The versioned Node addon patch also adds cancellation ABI 1. Atomic context
callbacks interrupt CPU evaluation during prefill and decode; GPU cancellation
waits for a scheduler graph boundary. Old addons cannot enable specialist or
Beam/Muse downloads merely by copying a provenance stamp. A timed-out ordinary
model initialization retains its reservation until the actual load finishes;
retrying joins that same load. Specialist and image work use an exclusive memory
lease, releasing idle text weights before checking available memory. Text model
selection and conversation state are retained across that lease.

### Still-image questions

**Ask about an image** installs each complete language-model/projector pair from
`shared/vision-models.json`. It covers MiniCPM-V 4.7 1B and 35B-A3B, and Nemotron
3.5 Super VL 120B-A12B. Their minimum available-memory floors are 8, 32 and 96 GiB.
The app accepts one selected JPEG or PNG, at most 8 MiB, 4,096 pixels on either
side and 16 million pixels. It preserves the selected file and question after
failure or cancellation. Video, audio and tool requests are unavailable.

The app bounds each question to 8,192 UTF-8 bytes, a 4,096-token context and 512
output tokens. The C bridge checks actual token/image context usage before
decoding and buffers only the final answer. Its bounded decoder allocator also
rejects small compressed PNGs that expand beyond the allocation budget.
Both native and desktop workflows install the complete pinned pair, verify both
files and recheck available memory before loading. These are still-image question
tools, separate from the selected text answer model.

Apple and Android link the C bridge into their existing Prism runtime. Electron
uses one static worker in a child process; model paths and prompts travel over
bounded stdin. On a hosted target-OS builder, after preparing the pinned source:

```sh
python3 scripts/build_vision_runtime.py build --source /absolute/prepared/prism-source --work /absolute/new/vision-build
python3 scripts/test_vision_runtime.py --source /absolute/prepared/prism-source --work /absolute/new/vision-fixtures
```

The build helper stages the worker, notices and provenance into the existing
`build/vision/<platform>-<arch>` resource directory. Packaging verifies the exact
worker, dependency closure, compiled ABI, source patch and artifact manifest.
These commands compile code and run synthetic fixtures; they download no weights.

### Hy-Memory proposals

The dedicated **Hy-Memory proposals** workflow uses the pinned 18,236,702,240-byte
community conversion in `shared/hy-memory-artifacts.json`. It is a separate
memory writer with a 32 GiB available-memory floor. Paste only the selected
conversation, preview proposals, then explicitly select which facts to save.
Nothing subscribes to conversations or persists a generated fact automatically.

The official no-thinking HY template, temperature zero and 512-token output cap
are fixed. The parser requires one complete object containing only `memories`,
at most 64 strings of 1–512 characters; duplicate fields, reasoning and trailing
content are rejected. Approved records use app-private storage and idempotent
identities. POSIX permissions and a verified protected Windows DACL are separate
platform implementations. The older general Notes bank is not repurposed.
Native Apple, Android and desktop workflows keep proposals unchecked until the
user approves them. The community converter's expert-width correction from 1,536
to 768 matches the pinned publisher configuration and existing `hy_v3` tensor
shapes; it is not full-weight inference validation or permission to rewrite an
arbitrary imported file.

### Granite Switch 4.1 8B

The official checkpoint is `ibm-granite/granite-switch-4.1-8b`, pinned in
`shared/granite41-source.json`; it is not the older 3B preview. The converter
requires the four complete source shards and pinned metadata already on disk.
It fetches no weights, installs no dependencies and executes no remote model
code. Use the existing environment containing the prepared runtime's converter
dependencies:

```sh
python3 scripts/convert_granite41.py --runtime-source /absolute/prepared/prism-source --model-dir /absolute/installed/granite --verify-only
python3 scripts/convert_granite41.py --runtime-source /absolute/prepared/prism-source --model-dir /absolute/installed/granite --output /absolute/new/granite-switch-4.1-8b-q8_0.gguf --outtype q8_0
```

The converter creates a new GGUF plus an adjacent `.quenderin.json` record and
never replaces existing output. Keep both together. The native Apple, Android and
desktop Granite chat workflows select and hash that pair, verify actual
`graniteswitch` architecture, 40 weight layers, 4,096 embedding width and a single
complete file. They require
the pinned converter record and at least 32 GiB of available memory, with a
further file-size/context allowance. The receipt is local conversion evidence,
not a publisher signature or inference validation. Dedicated text chat uses the
publisher's role template without activating decision, guardian or speech modes.
The generic unverified family guard remains closed; this explicit receipt-based
import is the supported source path for the official 8B checkpoint.

### Step 5 Preview on an existing CUDA host

Step 5 uses its official vLLM CUDA backend on the user's own suitably sized Linux
GPU host. Quenderin does not provision a server or claim this 600B-class model
fits on a phone. `shared/step5-backend.json` pins the official model and backend
revisions, all 26 required weight files (**644,100,979,280 bytes**) and metadata.
With that exact checkout, checkpoint and dependency environment already installed:

```sh
python3 scripts/run_step5_backend.py --source /absolute/installed/official-vllm --model /absolute/installed/step5 --verify-only
python3 scripts/run_step5_backend.py --source /absolute/installed/official-vllm --model /absolute/installed/step5 --tensor-parallel-size 4
```

The launcher verifies source and artifacts, disables model downloads and starts
an inner backend plus a loopback gateway. Defaults are ports 18001 and 18000.
Use an existing SSH tunnel to the client's literal loopback address, or a secured
HTTPS reverse proxy configured for the gateway's loopback Host policy. Never
expose the gateway directly on a public interface. The app requires explicit
consent for the selected gateway before sending a conversation and checks the
pinned readiness contract before each answer. Clients use system TLS validation,
no automatic credentials, cookies, redirects or retries, a 180-second deadline,
eight exchanges, 32 KiB of history and at most 1,024 output tokens. The gateway
admits one GPU request and propagates client disconnection upstream. This app
workflow currently supports text chat; it does not send images to Step 5.
The native Apple, Android and desktop clients use this same remote-specialist
contract. Prompts leave the device for the selected host only after consent.

### Image generation and future artifacts

The separate image workflow covers FLUX 3 Image Klein and MOSS Image Base/SFT.
`shared/image-model-catalog.json` pins the complete model, text encoder, VAE and
MOSS tokenizer sets. Import the original components through the app; gated FLUX
files require the user's own publisher access and license decision. The app does
not accept publisher terms or download gated weights on the user's behalf. The
native image runtime stays isolated from Prism's GGML symbols and releases its
resources before text restoration. Its available-memory floor is 24 GiB.
Native clients provide explicit component installation/import. The desktop Images
screen and CLI verify a manually prepared component directory, then save a new
PNG without overwriting an existing file. The ordinary answer model is not used
to expand a short FLUX prompt automatically; supply a complete scene caption.

Nemotron Bolt E4B has no verified public artifact in this candidate. It stays
unavailable; no guessed revision, placeholder download or substitute model is
presented as that release.

### Candidate checks

Run catalog/provenance checks and targeted TypeScript/UI tests. The additional
weight-free fixtures exercise real C/Swift/JNI interfaces, cancellation and
cleanup, controlled decoder failure, conversion methods, multipart integrity,
Step 5 transport and private-store permissions. Process-exit cleanup closes new
admission and joins active native work, including child-process exit, before
disposing the shared backend. Ordinary per-service cleanup retains that backend.

Final engineering revision
[`1d5f4452b0dd096fdaab737bc4581562f3bce666`](https://github.com/alikatgh/quenderin/commit/1d5f4452b0dd096fdaab737bc4581562f3bce666)
passed **all 18 jobs** in
[CI 39106905620](https://github.com/alikatgh/quenderin/actions/runs/39106905620).
The separate [catalog URL run 39106905664](https://github.com/alikatgh/quenderin/actions/runs/39106905664)
also passed at the same revision.

Hosted checks built the actual iOS and universal macOS Prism frameworks and
vision bridge, passed Swift tests and compiled the iOS app against the SDK.
Android built the actual JNI debug APK and unsigned release AAB, checked their
image-library identity, dependency closure and 16 KiB alignment, and passed core
and native runtime/memory-guard tests. Linux and Windows passed ASAR addon and
packaged image/vision probes; the macOS Electron lab package passed image/vision
runtime proofs. Separate image-runtime builds passed on all three systems.
Windows ran the actual private approved-memory store tests and positive/negative
protected-DACL fixtures successfully.

These are source, compilation, host-test and package results. They do not establish
new signing, store submission or public availability. Full-weight inference for
the new models, generated-image quality, measured memory/speed, rendered native
UI and ARMv7 support remain unverified; the existing hosted Bonsai CPU generation
gate is separate. Local full type checking was blocked by optional Picovoice
declarations, and the broad local backend suite encountered sandbox socket/home
restrictions and a missing ONNX dependency; the integrated hosted jobs above are
the final engineering evidence. No local weights, device runs or simulator runs
were authorized or used for this update.

## 16 October 2026: smaller models and Muse Spark integration (historical snapshot)

The source catalogs now also include experimental manual choices for Bonsai 2
2B, 4B, and 9B. Their PTQ1_0 artifacts pin immutable publisher revisions and
SHA-256 hashes in all three catalogs and the shared manifest. Exact download
sizes are 429,183,456 / 949,549,920 / 1,997,486,976 bytes. Conservative footprint
estimates are 1.5 / 2.5 / 4 GB before the existing 1.3 overhead multiplier and
device headroom gate; these are not measured allocations. Only matching pinned
artifacts receive those smaller floors; unknown imported Bonsai retains the
7 GB floor. Defaults, runtime capability checks, and the 4,096-token cap remain.

Inspection of the existing Prism pin found the required Qwen3.5 2B/4B/9B,
PTQ1_0, Hadamard, and tied-embedding paths. This is source compatibility evidence,
not proof of loading or generation. The local Android vendored checkout is stock
(`0eca4d490e591d4e93058d07540cf47278a72577`); a release must still use the explicitly
selected, verified Prism source described below. No runtime pin was changed.

Muse is now a separate experimental native text integration in this candidate:
`shared/muse-spark-artifacts.json` pins all 22 Q2_K shards;
`shared/prism-runtime.json` pins the source patch and compiled capability ABI.
Native multipart installers, memory checks and final-channel parsers accompany it.
The exact 304,080,474,208-byte artifact is not a phone-sized model. Tools, audio,
vision, distributed execution and the Electron/CLI adapter remain unsupported.
See `website/blog-muse-engineering.html` for implementation and improvement work.
No full Muse load, inference benchmark or store update is established by source checks.

Verification is tracked per layer. Catalog parity now covers 18 models, including
Muse's 22 immutable artifacts. Source-provenance, compiled-capability verifier,
release-feed, native prompt and model-free multipart/channel tests are included.
Swift host checks cover both receipt invalidation and cancellation; Kotlin fixtures
cover aggregate progress, retained-file integrity and final-channel output. The
independent review's raw-generation and large-file cancellation findings are
release gates. Hosted builds must compile the actual patched C++ runtime and
native adapters. No full Muse inference or device/UI validation was performed.

Sources: [PrismML announcement](https://prismml.com/news/bonsai-2-family),
[official Muse GGUF](https://huggingface.co/ggml-org/Muse-Spark-Open-816B-A42B-GGUF).

## Existing 27B integration

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
deployment minima are iOS 16.4 and macOS 13.3. The 0.4.0 candidate uses build 16;
refresh Cloud's counter before starting it.

On 12 October 2026, Xcode Cloud build 15 from
`9bab8d8aa67f2ecfdeb93b7a88cc4aed59592568` passed both App Store archive actions
and signed-export verification. On 16 October, both iOS and macOS 0.3.0 (15) were
verified **Ready for Distribution**. This does not establish distribution of the
new 0.4.0 candidate. See [RELEASE.md](RELEASE.md) for live console identifiers,
recovered signing procedure and the new release's remaining gates.

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
