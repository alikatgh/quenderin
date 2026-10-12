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
node node_modules/node-llama-cpp/dist/cli/cli.js source build --gpu false --noUsageExample
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
metadata, or backup directory; use a new build workspace if any exists. A
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

Run the normal catalog and model suites plus:

```sh
python3 -m unittest discover -s scripts/tests -p test_prism_runtime.py
python3 -m unittest discover -s scripts/tests -p test_prism_node_runtime.py
python3 scripts/check_catalog_parity.py
node --test scripts/tests/model-releases.test.mjs
```

The current integration needs a full pinned-runtime build, signed native release
artifacts, and an actual model load/generation check before a runtime-readiness
claim. Physical-phone testing was waived for this change. Local full builds and
the 5.95 GB model download were blocked by disk capacity during implementation.
Blog publication, source publication, native binaries and store availability are
separate release states.

Sources: [official model card](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf),
[Prism fork](https://github.com/PrismML-Eng/llama.cpp/tree/e8fd209c975c80aa7fb36a8423571ff3b1b7e955).
