# Apple MAX binding (source only)

Updated 25 October 2026. This is the Apple half of the
[mobile MAX work](max-mobile-integration.md). **MAX is not enabled:** no iOS
MAX artifact exists, the app links no vendor runner, and the Swift wrapper
fails closed when `runner` is nil. MAX is not selectable in model pickers or
Automatic.

## What landed

| Piece | Path |
| --- | --- |
| SwiftPM C target | `apple/QuenderinKit/Sources/CMaxModel/` |
| Staging receipt | `apple/QuenderinKit/CMaxModelStaging.json` |
| Swift wrapper | `apple/QuenderinKit/Sources/QuenderinKit/MaxModel.swift` |
| Tests | `apple/QuenderinKit/Tests/QuenderinKitTests/MaxModelTests.swift` |
| Staging/check tool | `scripts/stage_apple_max_model.py` |

SwiftPM cannot reference files outside the package root, so the canonical C
headers and implementation are staged byte-for-byte into the C target. The
staging receipt records the canonical path, size and SHA-256 of each file;
`--check` fails if the staged bytes drift. CI runs the check before `swift test`
and before the cross-target SDK build. There is no second maintained copy.

The Swift wrapper exposes receipt verification, capability, open, streaming
generation, cancel and close. `close()` waits for an active generation to drain
and returns `.busy` when called from the token callback itself. `cancel()` sets a
run-owned stop flag consumed by the C boundary, so a synchronous generation
cannot block cancellation; idle cancellation is a no-op. Tokens own pending and
terminal cancellation state; a delayed, completed or foreign token cannot cancel
a later run. Errors and numeric reports are Swift value types; no transcript,
path or prompt is put in an error.

## Tests

`MaxModelTests` uses a Swift fake `QMaxModelRunner` (test target only; never
shipped) and synthetic files:

- receipt verification and tamper rejection, rejected unsafe receipts;
- unavailable open with no runner;
- streaming `hello é!` across a split UTF-8 character;
- cancellation from the token callback and after admission but before the first
  token;
- BUSY while another run holds the lease;
- `close()` waits for the run to drain and returns `.closed`;
- idle cancel during a blocked close does not touch the model;
- token-owned cancellation is isolated from a successor run, including delayed
  token and delayed current-run requests;
- completed, foreign and already-consumed tokens are rejected;
- reuse after cancellation, idempotent close, closed-handle rejection;
- close from the callback is refused, not deadlocked.

Run on a hosted macOS runner:

```sh
python3 -B scripts/stage_apple_max_model.py --check
swift test --package-path apple/QuenderinKit
```

The same C target compiles for the iOS app through the existing Xcode build;
that is compilation, not an iOS MAX runtime.

## Verification status

- The prior Swift-runtime gap is closed for this source by the existing narrow
  hosted route: [`native-remote-sdk.yml` run 40221763739](https://github.com/alikatgh/quenderin/actions/runs/40221763739)
  on branch `codex/max-cancel-verification-20261026` at
  `a56a382f7f4272b904becae3888d8f1af551f1d4`. Both jobs completed SUCCESS:
  the [apple job 121254652114](https://github.com/alikatgh/quenderin/actions/runs/40221763739/job/121254652114)
  includes the QuenderinKit `swift test` step and the Apple/iOS SDK/app compile
  checks; the [android job 121254652255](https://github.com/alikatgh/quenderin/actions/runs/40221763739/job/121254652255)
  covers Android core tests and the SDK/app build.
- This is a **narrow two-job run**, not the full CI matrix. The earlier full-CI
  green set at `065b740` remains separate evidence and is not replaced by this
  run. The local host JNI/JVM synthetic fixture remains separate evidence
  described in [max-android-binding.md](max-android-binding.md).
- `110b67e` remains the accepted production-source revision; `a56a382` only
  updates documentation.
- No vendor MAX backend, model contract, physical phone, rendered UI or store
  verification is established. MAX remains disabled.
