# Engineering — what to improve ASAP

**Repo:** `/Users/s_avelova/Documents/projects/quenderin`  
**This pass (2026-08-22):** CPU-variant backends ON, JNI threadpool via registry, iOS `load_mode` dual-API, F16 `n_ctx` recompute + `nativeLoadedNCtx`, capability purpose i18n.  
**Scope:** code, native engine, CI gates, twin parity. Store / legal / testers / website copy are out.

| Layer | State after this pass |
|-------|------------------------|
| Android `.so` | `GGML_BACKEND_DL` + `GGML_CPU_ALL_VARIANTS` **ON**. Threadpool resolved via CPU backend registry. Vulkan still opt-in (SPIRV-Headers). versionName **0.2.1**. |
| iOS engine | `LlamaEngine.swift` dual-APIs `load_mode` vs `use_mmap` (Package.swift detects the header). F16 KV retry recomputes `n_ctx`. |
| Known failure modes | One ⏳ row left: **vision / mtmd**. |
| Golden chat CI | Structural only. Does not score tokens. |
| Hunt residue | 2026-08-09 findings still applied; do not re-open. |

---

## Done this pass

1. **CPU variants** — `android/jni/CMakeLists.txt` ON; `llama_jni.cpp` `resolve_cpu_threadpool_api()`; `useLegacyPackaging = true` kept.
2. **`nativeLoadedNCtx`** — Kotlin `loadedContextTokens` is the window llama actually created after q8→F16.
3. **iOS F16 retry** — `ContextWindow.recommend(..., .f16)` before the second `llama_init_from_model`. Test: `KVCachePolicyTests.testF16FallbackContextFitsTheSameBudget`.
4. **iOS `load_mode`** — `#if QUENDERIN_LLAMA_LOAD_MODE` in `LlamaEngine.swift`; Package.swift greps `llama.h`.
5. **Capability purpose i18n** — `scripts/translations.tsv` + Android `CapabilityCopy.kt` + ru/ko/ja/zh strings.

Vulkan was **not** flipped default-on: `ggml-vulkan/CMakeLists.txt` does `find_package(SPIRV-Headers CONFIG REQUIRED)` and the NDK does not ship it.

---

## Still P0

### Real vision / mtmd

Only remaining ⏳ row in `docs/KNOWN_FAILURE_MODES.md`. Pickers accept images and refuse honestly. Gemma 3/4 are vision-capable; no mmproj in the catalog, no `libmtmd` linked, no engine API takes image bytes.

Minimum shippable slice (twins, in this order):

1. Catalog: optional `mmproj` URL + SHA, parity-enforced. Only models that actually have a projector.
2. Native: link llama.cpp `mtmd` into the iOS xcframework and Android `libquenderin_llama.so`. MemoryFitness must count projector + embeddings.
3. Chat: image branch goes “embed + generate” when the loaded model has a projector; keep the refusal otherwise.
4. Golden gate: keep the refusal contract for text-only models; pin the vision-capable path too.

Do not silently drop images (`src/services/llm.service.ts` already documents that trap).

---

## P1

### On-device proof that variants loaded

`android/verify-llama-link.sh` already prints prefill vs decode. On a real i8mm phone, **prefill must be several× decode**, and logcat should show `backends: N device(s)` with N>0 (2026-07-02 packaging bug: N=0 meant the scan missed the `.so`s). This cannot be faked in CI without a device.

### Token-quality eval

`npm run check:golden-chat` is structural. Add a model-gated job (skip if no GGUF): shipped starters, tiny + small tiers, non-empty, no degeneration loop, print tok/s + TTFT.

### Vulkan

Opt-in remains `-Pquenderin.vulkan=true`. Flip the Gradle default only after SPIRV-Headers is in the build image. `GpuOffloadPlanner` already gates Adreno vs Mali.

---

## Not ASAP

| Item | Why it waits |
|------|----------------|
| Re-run a whole-repo hunt | Last one 2026-08-09; confirmed items fixed. |
| Twin-drift P2/P3 | Seam polish. |
| Desktop Electron a11y | Desktop is not the product. |
| NPU / Core ML / QNN | Decode is memory-bandwidth bound. Metal + (later) Vulkan first. |
| Store / legal / testers | Not engineering. |

---

## Verify

```sh
python3 scripts/build_xcstrings.py
cd apple/QuenderinKit && swift test --filter KVCachePolicyTests
# Android brain (no NDK): see android/README.md CoreVerify
android/verify-llama-link.sh   # real decode; needs complete NDK + a GGUF
```

On device after this cut: logcat `affinity: threadpool API resolved via CPU backend registry` and `backends: N device(s)` with N>0. If prefill ≈ decode, the variant `.so`s did not load.

**Next engineering session:** vision/mtmd (catalog twins first), then the on-device pp/tg confirm, then golden-eval.
