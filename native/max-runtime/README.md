# MAX native tensor bridge

This module implements `qmax_open`, `qmax_execute` and `qmax_close` over MAX's
real C API. It owns runtime/model/tensor lifetimes, checks bounded float32 shapes,
commits output only after validation and checks stop requests between synchronous
execution steps. The fixture exports a four-element CPU graph and expects
`[2, 6, 12, 20]` from the native executor.

The bridge is groundwork for a model adapter. It does not tokenize prompts,
load GGUF, generate language tokens or register MAX as a selectable mobile LLM.
A Bonsai adapter still requires a verified MEF/weight/tokenizer/cache contract,
and Android requires an actual NDK/Adreno port. MAX's public synchronous C API
cannot interrupt an execution already in flight; a supervising process deadline
is required. No pretrained model is used by this module's tests.

## Mobile model-adapter boundary

`include/quenderin_max_model.h` and `src/quenderin_max_model.c` add the
vendor-neutral lifecycle a mobile backend must satisfy: receipt files that are
always hashed (exact sizes and SHA-256), an exact runner ABI,
telemetry/crash-reporting opt-outs, single-flight generation, bounded
prompt/output/context/stream budgets, strict UTF-8 reassembly across token
pieces, cancellation at token boundaries, capability probing and numeric
performance reports. `qmax_model_close` refuses with `QMAX_BUSY` while a
generation is active. It owns no tokenizer, sampler, weights or GGUF loader;
those stay in the vendor runner.

Run the inert fixture (no SDK, network, weights or device):

```sh
python3 -B native/max-runtime/tools/test_model_adapter.py --work "$HOME/quenderin-max-scratch"
python3 -B native/max-runtime/tools/check_mobile_lock.py
```

`mobile-lock.json` records the 25 October 2026 audit: pinned MAX 26.7 source has
no Android/Adreno/Qualcomm/Dragonfly paths, the Bonsai 2B GGUF is pinned but no
MEF/tokenizer/cache contract exists, redistribution and telemetry are
unreviewed, and no public source/build recipe for the reported Snapdragon
demonstration was located. The lock fails validation if any of those become support,
inference or phone-performance claims. See
[docs/max-mobile-integration.md](../../docs/max-mobile-integration.md).

Native wrappers now exist on both platforms but link no production runner:
Android uses `android/jni/max_jni.cpp` plus
`MaxModelBinding.kt` ([binding record](../../docs/max-android-binding.md)); Apple
uses a byte-staged SwiftPM C target plus `MaxModel.swift`
([binding record](../../docs/max-apple-binding.md)). Opening reports unavailable
until a reviewed runner exists, and MAX is not selectable in the app.

## Source and SDK identity

The C interface and graph exporter follow Modular source
`527d069ee11a41ac5320af1f9402db0a66b2b868` (`max/v26.7.0`).
`sdk-lock.json` pins 17 official wheels (262,318,881 bytes), eight C headers,
exact selected-wheel PEP 658 metadata and aggregate transfer/extraction limits.
Its reviewed CPU-fixture lock SHA256 is
`6b5c5d4edb57cc45f52cf1b23a9faac30e10a17198aa72ed08b2f25a042fb70a`.
Any change to the lock, including its license review, changes the required hash.
See [NOTICE.md](NOTICE.md) for source attribution and binary-license boundaries.

## Verify without loading the SDK

From the repository root, with Python 3.12:

```sh
python3 -B -m unittest discover -s native/max-runtime/tests -p 'test_*.py'
python3 -B native/max-runtime/tools/check_source.py
```

The `MAX native CPU graph bridge` PR job additionally compiles and executes an
injected C-API implementation under sanitizers to test lifecycle and error paths.
That is a test double, not evidence of successful MAX execution.

## Inspect the actual SDK, then execute the real graph

Use the existing public GitHub runner workflow; do not install this SDK as an
unnecessary local build prerequisite. Once the workflow is on the default branch:

```sh
gh workflow run max-runtime.yml --ref main \
  -f mode=audit \
  -f reviewed_lock_sha256=6b5c5d4edb57cc45f52cf1b23a9faac30e10a17198aa72ed08b2f25a042fb70a
```

Audit mode downloads exact inert bytes, verifies hashes and archive paths, reads
the embedded package metadata/terms and reports the native library inventory.
It does not install/import MAX. Review the actual terms and `libmax.so` inventory;
do not substitute the source tag's older Community License or a newer source
license for the installed binary's terms.

[Audit 40099566447](https://github.com/alikatgh/quenderin/actions/runs/40099566447)
verified the exact metadata, found `libmax.so`, and extracted the actual binary
terms. Five required Modular wheels have no separate embedded terms file; all
six Modular packages declare the same MAX platform license. The follow-up
[nonexecuting audit](https://github.com/alikatgh/quenderin/actions/runs/40101507948)
records exact ELF dependencies and Python import evidence. The CPU profile omits
the entire `max-shmem-libs` wheel and the original `shmem.mojoc`, which its upstream
Linux recipe links with NVSHMEM device bitcode. Those payloads remain forbidden.
Their terms restrict development use to NVIDIA GPU systems.

Simply removing the module prevents CPU graph compilation, as
[attempt 40104752084](https://github.com/alikatgh/quenderin/actions/runs/40104752084)
demonstrated after the installation/absence checks and SDK import succeeded.
The source-built profile pins nine Apache/LLVM upstream files (474,306 bytes)
and uses the upstream `mojo precompile` recipe without GPU bitcode or host data.
Ten retained dependency modules, compiler bytes, arguments and generated output
are checked and receipted before SDK Python import. Missing components cause
failure; there is no fallback installation of the original binary.

The standalone C executor also needs the reviewed SDK resource root. Its
allowlisted `MODULAR_MOJO_MAX_PACKAGE_ROOT` points to `sdk/modular`, following the
[pinned official launcher](https://github.com/modular/modular/blob/527d069ee11a41ac5320af1f9402db0a66b2b868/Mojo/python/mojo/run.py#L42).
An ambient value is never inherited. `LD_LIBRARY_PATH` alone cannot supply the
compiler runtime and other JIT resources resolved relative to that root.

The lock binds the exact profile, metadata receipt and versioned terms coverage.
Before every SDK process, guards verify retained files and notices against the
source archives, reject omitted or renamed payloads, and check loader cache,
maps, preload and search paths. SDK Python starts without site initialization.
Original wheel staging is removed before SDK use. These controls must also pass
on the actual hosted installation; source tests alone do not establish that it
works. The retained fixture is metadata only, not an SDK or model artifact.

For any changed SDK, record the new audit's exact license map and explicit
per-package applicable-terms evidence in `runtime_license_review`, rerun the
guards and independently review component applicability and the change. The only
permitted review scope is `hosted-cpu-fixture-only-no-redistribution`; it does not
clear mobile redistribution or a managed service. Compute the new lock hash, then
dispatch `mode=execute` with that hash. Missing, incomplete or mismatched coverage
prevents both installation and execution. Matching package license declarations
alone never authorize shared coverage.

Execution compiles the real bridge, exports the CPU graph and invokes the native
executor in a separate network namespace as a non-root process without
capabilities. Telemetry and crash reporting are disabled before SDK initialization.
An environment allowlist, combined output cap, CPU/address-space/file limits,
aggregate deadline and process-group cleanup bound the fixture. The workflow
retains no SDK artifact/cache and clears its own hosted scratch.

Record source revision, workflow run, lock hash and actual result separately from
the test-double result. Passing this graph does not establish Bonsai generation,
Metal/Adreno support, phone speed, or store readiness.

## Verified actual SDK execution

[Hosted run 40174916756](https://github.com/alikatgh/quenderin/actions/runs/40174916756)
passed at source `dfa3db7494be35706608a285b7ce298d3013826a` on 25 October 2026.
All 35 Python guards, the sanitizer-backed injected C lifecycle suite, exact SDK
installation, source-module precompile, graph export and real C execution passed.
The native executor returned `[2, 6, 12, 20]` on three executions and rejected a
wrong shape and a stop request before execution. The isolation/telemetry guards
passed, NVSHMEM was unavailable to the loader, and hosted cleanup completed.

| Receipt | SHA256 |
| --- | --- |
| Reviewed SDK lock | `6b5c5d4edb57cc45f52cf1b23a9faac30e10a17198aa72ed08b2f25a042fb70a` |
| CPU source profile | `2e6a0e6de258a3f680079821f415e4e4739632b7724df98eea2942fcdfeb3586` |
| Generated `shmem.mojoc` | `0b270041afd4ccaea6763f5bf79bb92570225016d9fbc1831104ac31ca67c090` |
| Exported graph | `2ab0e1cc844efeda2f0ec1eee5c6177116b9a37b20218d37f41e74406f3b7d0a` |

These identify this successful run; later compiler output need not be byte
identical. The workflow checks current inputs and produces fresh receipts on
each execution. No pretrained model, native mobile SDK or distributed app was
tested by this graph.
