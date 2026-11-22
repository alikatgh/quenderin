# Quenderin Native Speech Runtime (`native/speech`)

`native/speech` provides a symbol-isolated C ABI (`quenderin_speech_*`) and CLI/JNI
bridges around `anomalyco/transcribe.cpp` (`60bed89dab84f7c1fddc3a17ad7fa8a27ddfba19`, MIT)
and `anomalyco/hex` (`fd2fafc91b67754065af17b9db70bb1cbbc13bb1`, MIT).

Like `native/diffusion/`, the shared library keeps `ggml` and `transcribe.cpp` internal:
only `quenderin_speech_*` symbols are exported so the speech runtime can coexist in-process
with Prism (`llama.cpp`) and `quenderin_diffusion` (`stable-diffusion.cpp`) without symbol or
GGML ABI collisions.

> **Verification status:** Source-level integration and synthetic host fixtures only
> (`inferenceVerified: false` in `shared/speech-runtime.json`). Full-weight inference and
> microphone hardware capture require user-selected GGUF models and hosted native builds.
