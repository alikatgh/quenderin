# Local image runtime

This is an experimental source integration of FLUX 3 Image Klein and MOSS Image
Base/SFT. No model weights or generated-image inference were used to verify it.
The immutable component manifests are `shared/image-model-catalog.json`; the
upstream source and patched GGML pins are `shared/diffusion-runtime.json`.

Build this directory in a **separate CMake configure** from llama.cpp. The image
runtime uses patched GGML, including `GGML_MAX_NAME=160` and INT8-convrot support.
Reusing llama's `ggml` CMake target or merging both static archives is unsafe.
The final dynamic framework/ELF library exports only `quenderin_diffusion_*`.
`scripts/prepare_diffusion_runtime.py verify-library` must pass for each slice.
The Apple build also renames GGML's Objective-C helper class to
`QuenderinDiffusionMetalClass`; hidden exports alone cannot isolate ObjC classes.

On hosted builders:

```sh
python3 scripts/prepare_diffusion_runtime.py fetch --destination "$RUNNER_TEMP/quenderin-diffusion-source"
cmake -S native/diffusion -B "$RUNNER_TEMP/quenderin-diffusion-build" \
  -DDIFFUSION_SOURCE_DIR="$RUNNER_TEMP/quenderin-diffusion-source" -DCMAKE_BUILD_TYPE=Release
cmake --build "$RUNNER_TEMP/quenderin-diffusion-build" --target quenderin_diffusion -j 2
```

For Android use the project's NDK toolchain, `arm64-v8a` and API 28 or higher;
the final DSO sets 16 KB ELF segment alignment. Keep its own GGML/backends private
and use `c++_static` inside each isolated DSO. Only C/JNI types cross their
boundary; hidden C++ symbols and contained exception/allocation ownership avoid
an additional shared-STL dependency. The final package verifier checks ELF
dependency closure and 16 KB segment alignment, as well as the exact image bytes.
For Apple, cross-build the dynamic framework for the actual iOS/macOS SDKs with
Metal embedded, set the existing deployment minima, then assemble an XCFramework.
No simulator is needed to compile the device and macOS slices. Sign/embed the
framework through the existing Xcode Cloud application workflow.

Windows desktop uses the same private patched-GGML DLL and CLI. In a hosted
Visual Studio 2022 x64 developer environment, after the source fetch above:

```powershell
cmake -S native/diffusion -B "$env:RUNNER_TEMP/diffusion-build" -A x64 `
  -DDIFFUSION_SOURCE_DIR="$env:RUNNER_TEMP/quenderin-diffusion-source"
cmake --build "$env:RUNNER_TEMP/diffusion-build" --config Release `
  --target quenderin_diffusion quenderin-diffusion-cli --parallel 2
python scripts/prepare_diffusion_runtime.py verify-library `
  --library "$env:RUNNER_TEMP/diffusion-build/bin/quenderin_diffusion.dll" --platform windows
& "$env:RUNNER_TEMP/diffusion-build/bin/quenderin-diffusion-cli.exe" --version
```

Release/debug output paths are stable: `bin/quenderin_diffusion.dll`,
`bin/quenderin-diffusion-cli.exe`, and `lib/quenderin_diffusion.lib` (import
library, not a second inference runtime). Package the DLL beside the executable
and use the project's existing MSVC runtime distribution. The `.def` file lists
the seven shim exports; automatic Windows symbol export is disabled. Inspection
uses `dumpbin /EXPORTS` or `llvm-readobj --coff-exports`, and fails closed if
neither inspector exists or any unexpected symbol is exported.

Windows API paths and CLI arguments support UTF-8/UTF-16 conversion. Only local
drive paths are accepted: UNC, device namespaces, alternate data streams, DOS
device aliases, reparse points and trailing-dot/space aliases are refused. Model
handles and their ancestors remain pinned while the upstream path-based loader
runs. Output creation holds parent handles, uses `CreateFileW(CREATE_NEW)`, and
checks the resulting handle's final path before writing pixels. Writes are
bounded and flushed; failure cleanup marks only the same newly created file
handle for deletion. A failed close/cleanup can retain that new output, and never
authorizes deleting a path that may now name another file.

Small hosted Windows filesystem checks do not need upstream source or weights:

```powershell
cmake -S native/diffusion/tests -B "$env:RUNNER_TEMP/diffusion-fixtures" -A x64
cmake --build "$env:RUNNER_TEMP/diffusion-fixtures" --config Release --parallel 2
ctest --test-dir "$env:RUNNER_TEMP/diffusion-fixtures" -C Release --output-on-failure
python scripts/prepare_diffusion_runtime.py verify-library `
  --library "$env:RUNNER_TEMP/diffusion-fixtures/bin/quenderin_diffusion.dll" --platform windows
```

These synthetic checks cover Unicode PNG output, existing/racing originals,
Windows aliases, pinned parents and reparse rejection. Reparse tests are marked
skipped (exit 77) when Windows symlink privileges are unavailable; a skip is a
verification gap. The fixtures do not fault-inject `WriteFile`/flush failures or
establish actual Windows model inference.

Swift imports `QuenderinDiffusion`; JNI should call the same small C ABI from its
own adapter. No upstream/GGML structures cross that boundary. Call generation on
a worker actor/executor. A single process-wide image job is admitted; concurrent
requests return `BUSY`. Cancellation uses the real upstream cancellation API.
The upstream synchronous model loader cannot be interrupted: cancellation during
loading is remembered and stops before sampling once loading returns.

Components must already exist at canonical absolute local paths. The runtime
does no networking or installation. Run `verify-components` after installation
and before exposing a model as ready. Keep request strings/reference pixels and
the engine handle alive until the synchronous call returns. Destroy only after
generation returns. Native callers marshal progress to their UI thread.

The output is one PNG at a caller-provided **new** path. Existing files and
symlinks are refused. Dimensions are multiples of 16 from 64 through 1024;
steps 1–50, threads 1–8, references at most 10. MOSS accepts text only. FLUX takes
full scene captions: expand prompts and reference-image edits with a local LLM
before calling this ABI. The source integration does not include that LLM.
Package bytes are disk requirements, not measured peak RAM; mobile availability
needs a conservative hardware gate and later real inference evidence.

The runtime is MIT and MOSS weights are Apache-2.0. FLUX weights are publisher
gated under FLUX Kommunity License v1.0. The license has purpose, distribution,
filter/review, attribution and qualifying-user restrictions; its production-output
exception is not blanket permission to redistribute a commercial model product.
This repository does not accept those terms or download gated files. A catalog
entry and a separately licensed generic runtime do not establish legal clearance
for a particular app deployment. Preserve publisher notices and require the user
to complete publisher access and license review before model installation.
