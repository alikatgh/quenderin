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

## Source and SDK identity

The C interface and graph exporter follow Modular source
`527d069ee11a41ac5320af1f9402db0a66b2b868` (`max/v26.7.0`).
`sdk-lock.json` pins 17 official wheels (262,318,881 bytes), eight C headers,
exact selected-wheel PEP 658 metadata and aggregate transfer/extraction limits.
Its reviewed CPU-fixture lock SHA256 is
`74fbb48b0573a8a985256a90a8848a7997ba2c25e3a3a9598b2e712e29859265`.
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
  -f reviewed_lock_sha256=74fbb48b0573a8a985256a90a8848a7997ba2c25e3a3a9598b2e712e29859265
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
the entire `max-shmem-libs` wheel and the exact audited `shmem.mojoc`, keeping the
GPU-only NVSHMEM implementation outside the installed runtime. Its terms restrict
development use to NVIDIA GPU systems. Missing components cause failure; there
is no fallback installation.

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
