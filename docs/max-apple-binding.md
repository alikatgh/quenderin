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
and returns `.busy` when called from the token callback itself. `cancel()` calls
the native atomic lease directly, so a synchronous generation cannot block
cancellation. Errors and numeric reports are Swift value types; no transcript,
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
- a concurrent `cancel()` waits for a blocked close to release the model lease;
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

- Staged C bytes verified by `--check`.
- `swiftc -typecheck` of the wrapper passed for macOS and
  `arm64-apple-ios16.4`; the C source passes the iPhoneOS SDK syntax check.
- `swift package dump-package` resolves `CMaxModel` as a package target.
- Hosted `swift test` and the iOS app compile are wired into CI; check the exact
  PR head.
- No MAX SDK, runner, weights, simulator or device was used. Phone speed and UI
  remain unverified, and Apple MAX packaging remains a separate artifact/license
  milestone.
