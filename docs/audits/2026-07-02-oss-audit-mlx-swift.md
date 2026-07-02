# OSS Audit — Apple MLX Swift LLM stack vs llama.cpp for Quenderin (iOS/macOS)

**Date:** 2026-07-02
**Auditor:** automated code audit (scratchpad clones, no Quenderin repo access)
**Repos audited (shallow clones):**
- `ml-explore/mlx-swift-examples` (example apps only — LLM libs moved out)
- `ml-explore/mlx-swift-lm` (**the real target** — `MLXLLM` + `MLXLMCommon` live here now)
- `ml-explore/mlx-swift` (grep-only — MLX core + Metal)

> **Structural note that changes the whole picture:** the LLM libraries
> `MLXLLM` / `MLXLMCommon` are **no longer in `mlx-swift-examples`**. They were
> extracted into a standalone package **`mlx-swift-lm`**
> (`mlx-swift-examples.xcodeproj/project.pbxproj:3915` →
> `https://github.com/ml-explore/mlx-swift-lm.git`). `mlx-swift-examples` now
> only carries the sample apps (LLMEval, MLXChatExample, LLMBasic, …) which
> `import MLXLLM` / `import MLXLMCommon` from that package. All file:line cites
> below are in `mlx-swift-lm` unless prefixed with `mlx-swift-examples/`.

---

## 1. TL;DR — verdict

**Recommendation: stay on llama.cpp for the shipping engine. Adopt MLX only as
an optional, macOS-first *second backend* behind the same engine seam, if and
when a measured win justifies it. Do NOT rip out llama.cpp.**

Rationale, evidence-first:

1. **MLX cannot load our GGUF catalog. Safetensors only.** `Load.swift:25`
   handles only `url.pathExtension == "safetensors"`; PyTorch `.bin` is
   explicitly rejected (`ModelConversion.swift:165`). The single "gguf" string
   in the repo is a wired-memory doc listing file extensions to lock in RAM
   (`Documentation.docc/wired-memory.md:39`), **not a loader**. Adopting MLX
   means a **parallel model catalog** (MLX-format safetensors from
   `mlx-community/*` on HF), parallel sha256 pins, and parallel download/verify
   — our entire GGUF acquisition layer does not transfer.

2. **No published perf numbers in-repo to justify a switch.** There is a
   benchmark *harness* (`Libraries/BenchmarkHelpers/BenchmarkHelpers.swift`,
   fetches Pride & Prejudice and measures load/prefill/decode) but **zero
   committed tok/s figures** anywhere in the tree (grep for `tok/s`,
   `tokens per second`, hard numbers → none in READMEs or source). So the core
   "is MLX faster?" question **is not answered by this repo** — it would need
   our own on-device A/B. Do not switch on faith.

3. **Platform floor is higher than ours.** MLX-swift-lm requires
   **iOS 17 / macOS 14 / visionOS 1 / tvOS 17** (`Package.swift:9-13`). Our
   llama.cpp build presumably reaches older iOS. For the **macOS client** this
   is a non-issue (macOS 14 is fine); for **iOS** it raises the floor.

4. **Where MLX plausibly wins is exactly our upcoming macOS client**: plentiful
   unified RAM, MLX's native 4/8-bit weights + quantized KV, and a genuinely
   nice `AsyncStream<Generation>` + `ChatSession` API. That's the hybrid: **MLX
   as an experimental macOS backend, llama.cpp everywhere we already ship
   (iOS + the Android side stays llama.cpp regardless — MLX is Apple-only).**

**Net:** hybrid, conservatively. The engine seam (`#if canImport(llama)`) is
already the right shape to host a second `#if canImport(MLX)` backend. Keep
llama.cpp as the default; prototype MLX on macOS behind a flag; only promote it
if our own benchmark shows a real tok/s or memory win on target hardware.

---

## 2. Capability table — MLX-swift-lm vs llama.cpp for OUR needs

| Need | MLX-swift-lm | llama.cpp (our current) | Winner for us |
|---|---|---|---|
| **Load GGUF** | ❌ No. safetensors only (`Load.swift:25`; `.bin` rejected `ModelConversion.swift:165`) | ✅ Native GGUF | **llama.cpp** |
| **Reuse our HF GGUF catalog / sha256 pins** | ❌ Needs MLX-format safetensors (`mlx-community/*`); new catalog + new pins | ✅ Already ours | **llama.cpp** |
| **Quantized weights** | ✅ Group-wise 4/8-bit, affine mode (`BaseConfiguration.swift:22-29`) | ✅ Q4_K_M etc. | tie |
| **Quantized KV cache** | ✅ `QuantizedKVCache(groupSize:64, bits:8)` default (`KVCache.swift:821,828`) + native quantized SDPA | ✅ (`cache-type-k/v`) | tie |
| **Sliding-window / rotating KV** | ✅ `RotatingKVCache(maxSize:keep:step:)` (`KVCache.swift:518,528`) — keep-prefix + rotate | ✅ context-shift (ours) | tie |
| **Prompt-cache persist to disk** | ✅ `savePromptCache`/`loadPromptCache` to `.safetensors`, Python-compatible (`KVCache.swift:1591,1637`) | partial (in-mem KV reuse) | **MLX** |
| **Streaming API shape** | ✅ `AsyncStream<Generation>` (`.chunk`/`.info`/`.toolCall`) `Evaluate.swift:2052`; `ChatSession.streamResponse → AsyncThrowingStream<String>` (`ChatSession.swift:479`) | C callback loop we wrap | **MLX** (ergonomics) |
| **Chat templates** | ✅ `applyChatTemplate(messages:tools:)` via swift-transformers + **swift-jinja** (`Tokenizer.swift:16`) — real Jinja, tools supported | `llama_chat_apply_template` (built-in templates) | MLX (Jinja is a superset) |
| **Prefill batching** | ✅ `prefillStepSize` default 512 (`Evaluate.swift:134`) | ✅ n_batch | tie |
| **Speculative / draft decoding** | ✅ `SpeculativeTokenIterator`, draft model, MTP drafter (`Evaluate.swift:771`; `MTPDrafterModel.swift`) | ✅ (llama.cpp has it) | tie |
| **Memory controls** | ✅ `Memory.cacheLimit` + **wired-limit ticket/policy system** tied to `GPU.maxRecommendedWorkingSetBytes()` (`WiredMemoryPolicies.swift`) | metal offload flags | **MLX** (richer) |
| **Thermal-adaptive threading** | n/a (GPU/Metal, unified) | ✅ ours | llama.cpp (our lever) |
| **OS floor** | iOS 17 / macOS 14 (`Package.swift:9-13`) | lower | **llama.cpp** |
| **Binary/dep weight** | Heavy: bundles MLX C++/Metal core + swift-transformers + swift-huggingface + swift-syntax macros | Single prebuilt `llama.xcframework`, zero SPM deps | **llama.cpp** |
| **Model catalog (Qwen3?)** | ✅ Qwen3 dense/MoE/3.5, Qwen2.5, Llama3, Gemma2/3/3n/4, Phi3.5, Mistral, DeepseekV3 (`LLMModelFactory.swift:41-83`) | ✅ any GGUF | tie (both have Qwen3) |
| **Licensing** | MIT (`LICENSE:1`) | MIT | tie |
| **Android** | ❌ Apple-only (Metal) | ✅ | **llama.cpp** |

**Bottom line of the table:** MLX wins on API ergonomics, prompt-cache
persistence, and memory-limit machinery. llama.cpp wins on the two things that
actually gate a migration for *us*: **GGUF catalog reuse** and **lower OS
floor + tiny dependency footprint + cross-platform (Android)**.

---

## 3. Migration cost estimate — what in QuenderinKit would change

The engine seam is **not** the expensive part. The model-acquisition layer is.

| QuenderinKit layer | Change under MLX adoption | Cost |
|---|---|---|
| **Engine seam** (`#if canImport(llama)`) | Add a parallel `#if canImport(MLX)` backend; both conform to a common `InferenceEngine` protocol. MLX's `generate(...) -> AsyncStream<Generation>` maps cleanly to a token stream. | **Low–Med** — the seam already exists |
| **Model catalog / registry** | **Rewrite.** MLX wants MLX-format safetensors (`mlx-community/…-4bit`), not our GGUF ids. New entries, new HF repos, new quant naming. Our Qwen3 4B Q4_K_M ≠ `mlx-community/Qwen3-4B-4bit`. | **High** — parallel catalog |
| **Download + sha256 pinning** | Rewrite. MLX pulls a **snapshot of many files** (`*.safetensors` + tokenizer + config, `ModelFactory.swift:7`) via swift-huggingface's hub downloader, not our single-GGUF + single-sha256 flow. Pin the whole snapshot or per-shard. | **High** — different acquisition model |
| **Chat templating** | Small. Move from `llama_chat_apply_template` to `applyChatTemplate` (Jinja via swift-transformers). Behaviorally equivalent-or-better, but a code path swap. | **Low** |
| **KV-cache / context-shift** | Re-map our context-shift onto `RotatingKVCache` (`maxSize`/`keep`/`step`). Concepts align. Optionally gain disk prompt-cache. | **Low–Med** |
| **Memory / thermal policy** | Our thermal thread-count lever is llama.cpp-specific and doesn't apply to MLX (GPU/unified). Under MLX we'd adopt `Memory.cacheLimit` + wired-limit policies instead. Two different tuning models to maintain. | **Med** |
| **Dependencies** | Currently *zero* external SPM deps. MLX adds: `mlx-swift`, `swift-transformers`, `swift-huggingface`, `swift-syntax` (macros) + transitive (swift-nio, swift-crypto, yyjson, swift-jinja…). Big footprint jump. | **Med** — violates the "zero deps" property |

**Verdict on cost:** the engine seam alone is a weekend. But MLX drags in a
**whole parallel model-acquisition + catalog + pinning subsystem** because it is
safetensors/HF-snapshot-native. That is the real bill, and it's why a *hybrid*
(MLX as an optional macOS backend, gated, with its own small MLX catalog) is far
cheaper than a *migration*.

---

## 4. Performance evidence found in-repo

**None quantitative.** This is important and I will not invent numbers.

- A benchmark **harness** exists — `Libraries/BenchmarkHelpers/BenchmarkHelpers.swift`
  (`BenchmarkStats`, `BenchmarkTextSource.prideAndPrejudice`) measures model
  load, tokenizer, prefill, and decode timings.
- Runtime metrics are computed and exposed:
  `GenerateCompletionInfo.tokensPerSecond` / `.promptTokensPerSecond`
  (`Evaluate.swift:1082-1094`, `2007-2012`), surfaced through the
  `Generation.info` stream case.
- **But there are no committed tok/s results** in any README or source file
  (grep for `tok/s`, `tokens per second`, and bare numeric `tok` across
  `*.md`/`*.swift` → zero hits with actual figures).

**Consequence:** the headline question — "is MLX faster / lower-memory than
llama.cpp on A17+/M-series?" — **cannot be answered from this repo**. It must be
measured on our own hardware with our own models before any adoption decision.
The harness above is a good starting point for that A/B.

---

## 5. Cleverness worth stealing regardless of adoption

These are portable ideas we can bring into the llama.cpp path today:

1. **Disk-persisted prompt cache** (`KVCache.swift:1591 savePromptCache`,
   `1637 loadPromptCache`; `ChatSession.swift:306` "prefix caching"). Prefill a
   long shared context (system prompt + pinned document) **once**, serialize the
   KV state to a file, and restore it across app launches — skipping re-prefill
   entirely. llama.cpp has `llama_state_seq_save_file`/`load_file`; we likely
   don't use it yet. Big latency win for a fixed system prompt. **Steal this.**

2. **Wired-memory ticket/policy system** (`WiredMemoryPolicies.swift` —
   `WiredSumPolicy`, `WiredMaxPolicy`, `WiredFixedPolicy`, `WiredBudgetPolicy`;
   `WiredMemoryUtils.tune(...)` measures weights + KV + prefill workspace,
   `WiredMemoryUtils.swift:145-175`). It clamps wired RAM to
   `GPU.maxRecommendedWorkingSetBytes()` and does **admission control**
   (`canAdmit`) before starting work. The *pattern* — measure
   weights+KV+workspace, set a budget, refuse work that won't fit — is exactly
   the memory-pressure discipline we want on iOS regardless of engine.

3. **`AsyncStream<Generation>` with a 3-case enum** (`.chunk` / `.info` /
   `.toolCall`, `Evaluate.swift:2052`). Clean model for our SwiftUI layer: text
   deltas, a terminal metrics payload, and tool calls on one stream. Worth
   mirroring in our engine wrapper's public API even over llama.cpp.

4. **`ChatSession` façade** (`ChatSession.swift`): `respond(to:) async -> String`
   and `streamResponse(to:) -> AsyncThrowingStream<String>` that internally own
   the KV cache across turns, support tool dispatch, and can be seeded from a
   loaded prompt cache. A tidy conversation-state abstraction to emulate.

5. **`prefillStepSize` (default 512)** batched prefill (`Evaluate.swift:134`) —
   confirm our llama.cpp `n_batch` for prompt ingestion is tuned similarly;
   cheap throughput on long prompts.
