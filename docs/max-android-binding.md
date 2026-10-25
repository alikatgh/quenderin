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
runs on the generation thread. Cancellation is an atomic run ID plus the C
lease and may arrive from the sink, another thread or the UI. A stale run ID is
ignored. `nativeClose` refuses with `QMAX_BUSY` while a run is active.

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
closed handle. The fake runner is never compiled into the app.

The app's hosted Android job builds `libquenderin_max_jni.so` for arm64 through
the existing CMake external build; that compile is the packaging check. It does
not establish a vendor backend or phone execution.

## Verification status

- Kotlin facade compiled locally with kotlinc; the JNI C++ passes
  `clang++ -fsyntax-only -Wall -Wextra -Werror` against the JDK headers.
- Hosted JNI/JVM and arm64 app compilation are wired into CI; check the exact
  PR head.
- No MAX runner, weights, device or simulator was used. Phone speed and UI
  remain unverified.
