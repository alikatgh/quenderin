# Android MAX binding (source only)

Updated 25 October 2026. This is the Android half of the
[mobile MAX work](max-mobile-integration.md). **MAX is not enabled:** the app
build links no vendor runner, so every open reports unavailable and MAX is not
selectable in model pickers or Automatic.

## What landed

| Piece | Path |
| --- | --- |
| JNI bridge | `android/jni/max_jni.cpp` |
| CMake target | `android/jni/CMakeLists.txt` (`quenderin_max_jni`) |
| Kotlin facade | `android/quenderin-core/src/main/kotlin/ai/quenderin/core/MaxModelBinding.kt` |
| JVM unit tests | `android/quenderin-core/src/test/kotlin/ai/quenderin/core/MaxModelBindingTest.kt` |
| Hosted JNI/JVM fixture | `android/quenderin-core/src/verify/MaxModelVerify.kt` |
| Hosted builder | `native/max-runtime/tools/test_android_binding.py` |

The bridge compiles the canonical C implementation once; it does not copy or
fork it. Handles are registry IDs, not raw pointers. Each call holds a
`shared_ptr`, so a concurrent close cannot free state under a caller. The Java
lease and the C lease must both admit before generation touches the model.

Callbacks are resolved to `MaxTokenSink.onToken(String): Boolean`; the callback
runs on the generation thread. Cancellation is run-owned: each run has its own
pending, active or completed state. A token cancelled before native admission
keeps an independent pending request; a completed or retired token is rejected,
and a delayed earlier token cannot cancel the active run. Pending requests are
bounded to 64 and terminal history to 1,024 completed IDs. Only terminal records
expire: unknown IDs at or below the retirement floor cannot be revived, while an
accepted pending request remains live even if that floor passes it.
`nativeClose` refuses with `QMAX_BUSY` while a run is active.

Prompt conversion preserves supplementary Unicode and embedded NUL; paths use
the strict converter and reject NUL. The bridge never treats JNI modified UTF-8
as ordinary UTF-8.

## Tests

The production build defines no runner. The hosted fixture builds the same
bridge with `QUENDERIN_MAX_TEST_RUNNER` and the synthetic C runner, then runs
the Kotlin facade through JNI:

```sh
python3 -B native/max-runtime/tools/test_android_binding.py --work "$HOME/quenderin-max-jni"
```

Cases: receipt verification and tamper rejection, unavailable production path,
capability after a real open, streaming text, supplementary scalar plus NUL,
cancellation from the sink, cancellation after admission but before the first
token, BUSY on a concurrent run, close-while-busy, reuse, idempotent close and a
closed handle. The JNI boundary rejects hash lengths 0/1/63 before copying, and
the Kotlin receipt snapshots its caller-owned file list so post-construction
mutation cannot change a verified receipt. Additional lifecycle coverage includes
independent pending requests, completed/retired token rejection, the 64 pending /
1,024 completed bounds with old unknown-ID expiry, delayed and current-run
successor isolation, and deterministic native admission/retirement regressions.
Two negative controls fail as expected. The fake runner is never compiled into
the app.

The app's hosted Android job builds `libquenderin_max_jni.so` for arm64 through
the existing CMake external build; that compile is the packaging check. It does
not establish a vendor backend or phone execution.

## Verification status

- Kotlin facade compiled locally with kotlinc; the JNI C++ passes
  `clang++ -fsyntax-only -Wall -Wextra -Werror` against the JDK headers.
- `110b67e`: the full host-only JNI/JVM synthetic fixture passed on Darwin arm64
  (clang, local JDK), and all nine Kotlin facade unit tests passed. Deterministic
  native admission and retirement regressions passed; two negative controls
  failed as expected. The fixture covers independent pending requests,
  completed/foreign/retired tokens, the 64 pending / 1,024 completed bounds,
  old unknown-ID expiry, delayed/current-run successor isolation, UTF-8/NUL,
  cancellation, BUSY, close and reuse. This local host evidence remains separate
  from the hosted run below.
- The narrow hosted route now passes on the exact docs/source revision:
  [`native-remote-sdk.yml` run 40221763739](https://github.com/alikatgh/quenderin/actions/runs/40221763739)
  on branch `codex/max-cancel-verification-20261026` at
  `a56a382f7f4272b904becae3888d8f1af551f1d4`. The
  [android job 121254652255](https://github.com/alikatgh/quenderin/actions/runs/40221763739/job/121254652255)
  passed Android core tests (including the nine facade tests) and the real
  Android SDK/app build. The
  [apple job 121254652114](https://github.com/alikatgh/quenderin/actions/runs/40221763739/job/121254652114)
  passed the QuenderinKit `swift test` step and Apple/iOS SDK/app compile checks.
- This is a **narrow two-job run**, not the full CI matrix, and it does not
  execute `test_android_binding.py`. The earlier full-CI green set at `065b740`
  remains separate evidence. `110b67e` remains the accepted production source;
  `a56a382` only updates documentation.
- No vendor MAX backend, model contract, physical phone, rendered UI or store
  verification is established. MAX remains disabled.
