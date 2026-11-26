# Ollama → Quenderin gap map

**Date:** 26 November 2026 (Asia/Ulaanbaatar)  
**Ask:** Albert, 26 Nov 2026, 2:34 PM UB — read [ollama.com/blog](https://ollama.com/blog) and do what they do in Quenderin: how they work and what they implement; “half of it we can easily implement.”  
**Scope:** research only. No code, no deploy, no store or site change.

## Sources

**Ollama:** [ollama.com/blog](https://ollama.com/blog) index (65 posts) plus full text of the feature posts cited below, fetched 26 Nov 2026.

**Quenderin:** checkout `/workspace/quenderin-v063` of [github.com/alikatgh/quenderin](https://github.com/alikatgh/quenderin) at `5e7b4d1` (merge of `release/apple-0.6.3`). A later website-only worktree is `/workspace/quenderin-download-063-20261126` (`website/download-0.6.3-20261126`, `6b969ef`). Live site checked: [quenderin.org](https://quenderin.org), [blog](https://quenderin.org/blog.html), [models](https://quenderin.org/models.html), [features](https://quenderin.org/features.html).

If this note is committed, the natural home is `docs/research/ollama-gap-map-20261126.md` in that repo (alongside `docs/research/on-device-llm.md` and `similar-projects.md`). Do not treat this file in `/workspace` as the long-term copy.

**Honesty rule used throughout:** `STATUS.md` and `docs/ROADMAP.md` are stale (July 2026 / v0.2.0). Prefer `FEATURES.md`, `CHANGELOG.md`, Apple/Android/desktop source, and the live site. Many October–November specialist workflows are in source with `inferenceVerified: false` and are explicitly “not a store build.” iOS 0.6.3 is live; macOS 0.6.3 was resubmitted 26 Nov and is waiting for review; Android 0.6.3 is in progress. Where store and source differ, this map says so.

---

## 1. Ollama blog — last ~18 months, one line each

Cadence, May 2025–Nov 2026: about 41 posts, roughly two to three a month, with bursts when a model drops. Tone is short, confident, present-tense (“now available”), usually a one-paragraph hook, a `get started` command, a curl/Python/JS snippet, and a link to a model or library page. They announce **features** and **new models** in the same voice; model-drop posts often land the same day as the weight release. Integrations (Claude Code, Codex, Claude Desktop, Continue, Docker, Autogen) are treated as first-class products. Performance posts include measured numbers. Cloud, pricing, and funding appear, but the default story is still local.

### Feature and practice posts (the ones that define “how they work”)

| Date | Title | Feature / practice |
|---|---|---|
| 16 Nov 2026 | [Making open models work for long-horizon agentic workloads](https://ollama.com/blog/open-models-long-horizon-agents) | Prefix caching across agent turns; keep prompts/tool defs stable so the KV/prefix cache hits; engine + harness must both protect the cache. |
| 24 Oct 2026 | [Speech models in Ollama](https://ollama.com/blog/speech-models) | Local TTS (Phonon), streamed audio, voices/languages, OpenAI-compatible `/v1/audio/speech`, pipe chat into speech. macOS first. |
| 13 Oct 2026 | [Run AI agents safely with Ollama and Fly.io](https://ollama.com/blog/fly-io-sprites) | Partnership: run Ollama cloud models inside isolated Fly.io machines. |
| 29 Sep 2026 | [Ollama now supports Jev-style decision models](https://ollama.com/blog/ollama-now-supports-jev-style-decision-models) | Typed yes/no, choice, and score APIs with probabilities (Jev / TypeSafe), not free-form chat. |
| 31 Aug 2026 | [Ollama's transparent pricing](https://ollama.com/blog/transparent-pricing) | Cloud Pro/Max/Team plans move to per-token pricing. (Cloud business, not a local feature.) |
| 25 Aug 2026 | [Claude Desktop support with Ollama](https://ollama.com/blog/claude-desktop) | Ollama as a third-party gateway so Claude Desktop can use open/local models. |
| 29 Jun 2026 | [Faster Gemma 4 on MLX with multi-token prediction](https://ollama.com/blog/faster-gemma-4-mlx-mtp) | MTP on Apple Silicon via MLX; measured coding-agent speedup. |
| 11 Jun 2026 | [Ollama's highest performance on Apple Silicon yet with MLX](https://ollama.com/blog/mlx-performance) | MLX engine update: faster, higher quality, less memory. |
| 5 Jun 2026 | [Improved performance and model support with GGUF](https://ollama.com/blog/improved-performance-and-model-support-with-gguf) | llama.cpp/GGUF path kept alongside MLX, so more models and more hardware. |
| 30 Mar 2026 | [Ollama is now powered by MLX on Apple Silicon in preview](https://ollama.com/blog/mlx) | MLX preview: NVFP4, better prefix cache, `ollama launch` for Claude Code / OpenClaw. |
| 23 Feb 2026 | [The simplest and fastest way to setup OpenClaw](https://ollama.com/blog/openclaw-tutorial) | One-command setup tutorial for a local personal agent. |
| 16 Feb 2026 | [Subagents and web search in Claude Code](https://ollama.com/blog/web-search-subagents-claude-code) | Tooling integration: subagents + web search inside Claude Code via Ollama. |
| 1 Feb 2026 | [OpenClaw](https://ollama.com/blog/openclaw) | Personal assistant that ties messaging apps to local coding agents. |
| 23 Jan 2026 | [ollama launch](https://ollama.com/blog/launch) | `ollama launch` configures Claude Code, OpenCode, Codex with local or cloud models; no env/config files. |
| 20 Jan 2026 | [Image generation (experimental)](https://ollama.com/blog/image-generation) | Local image gen on macOS (`ollama run` a FLUX/Z-Image model); size/steps/seed/negative prompts. |
| 16 Jan 2026 | [Claude Code with Anthropic API compatibility](https://ollama.com/blog/claude) | Anthropic Messages API compatibility so Claude Code can talk to open models. |
| 15 Jan 2026 | [OpenAI Codex with Ollama](https://ollama.com/blog/codex) | OpenAI-compatible endpoint pointed at Codex CLI. |
| 24 Sep 2025 | [Web search](https://ollama.com/blog/web-search) | Hosted `web_search` / `web_fetch` API (API key, free tier + cloud limits) plus MCP wiring. |
| 23 Sep 2025 | [New model scheduling](https://ollama.com/blog/new-model-scheduling) | Better scheduler: fewer OOM crashes, fuller GPU use, multi-GPU. |
| 19 Sep 2025 | [Cloud models](https://ollama.com/blog/cloud-models) | Preview: keep local tools, run larger models on Ollama’s cloud. |
| 30 Jul 2025 | [Ollama's new app](https://ollama.com/blog/new-app) | Native macOS/Windows chat app: drag-and-drop files/PDFs, context-length setting, multimodal images. |
| 3 Jun 2025 | [Secure Minions](https://ollama.com/blog/secureminions) | Encrypted local–remote collaboration protocol (Stanford Hazy Research). |
| 30 May 2025 | [Thinking](https://ollama.com/blog/thinking) | User/API toggle to enable or disable thinking; thinking stream separated from the answer (`think`, `/set nothink`). |
| 28 May 2025 | [Streaming responses with tool calling](https://ollama.com/blog/streaming-tool) | Stream tokens and tool calls together; template-aware incremental parser; OpenAI-style tools + MCP. |
| 15 May 2025 | [Ollama's new engine for multimodal models](https://ollama.com/blog/multimodal-models) | First-class vision in the main chat path (Llama 4, Gemma 3, Qwen 2.5 VL, …). |

### Earlier foundations still in daily use (worth mapping even if older than 18 months)

| Date | Title | Feature / practice |
|---|---|---|
| 6 Dec 2024 | [Structured outputs](https://ollama.com/blog/structured-outputs) | Constrain replies to a JSON schema (`format`); Python/JS + OpenAI parse helpers. |
| 25 Jul 2024 | [Tool support](https://ollama.com/blog/tool-support) | Function/tool calling for Llama 3.1 and similar models. |
| 8 Apr 2024 | [Embedding models](https://ollama.com/blog/embedding-models) | `/api/embed`, small embedding models, RAG examples (LangChain, LlamaIndex). |
| 8 Feb 2024 | [OpenAI compatibility](https://ollama.com/blog/openai-compatibility) | `http://localhost:11434/v1/chat/completions` — existing OpenAI SDKs and apps just change the base URL. This is the distribution trick. |
| 2 Feb 2024 | [Vision models](https://ollama.com/blog/vision-models) | Image input in chat (LLaVA and later VL models). |
| 23 Jan 2024 | [Python & JavaScript Libraries](https://ollama.com/blog/python-javascript-libraries) | Official clients that track the REST API; later posts always update the libraries in the same announcement. |
| 5 Oct 2023 | [Official Docker image](https://ollama.com/blog/ollama-is-now-available-as-an-official-docker-image) | One official image, GPU on Linux, Docker Desktop on Mac. |

### Model-drop, hardware, and company posts (practice: ship the card the same week)

| Date | Title | Feature / practice |
|---|---|---|
| 19 Oct 2026 | [Clef is available on Ollama's cloud](https://ollama.com/blog/clef) | Cloudflare 27B multimodal decision model, local or cloud. |
| 16 Oct 2026 | [Reflection's Beam](https://ollama.com/blog/reflection-beam) | New coding/agent model, limited-time free on cloud. |
| 11 Aug 2026 | [NVIDIA Nemotron 3.5 Lightning](https://ollama.com/blog/nemotron-3-5-lightning) | 30B-A3B agent model on your own hardware. |
| 10 Aug 2026 | [Muse Glimmer from Meta Superintelligence Labs](https://ollama.com/blog/muse-glimmer) | 30B multimodal, Apache-2.0, MLX / DFlash / image input. |
| 9 Jul 2026 | [Ollama: all aboard open models](https://ollama.com/blog/all-aboard-open-models) | Funding announcement ($88M; 8.9M developers). |
| 4 Jun 2026 | [NVIDIA Nemotron 3 Ultra](https://ollama.com/blog/nemotron-3-ultra) | High-throughput reasoning / long agent workflows. |
| 28 May 2026 | [OpenJarvis](https://ollama.com/blog/openjarvis) | Third-party local-first agent framework with built-in Ollama support. |
| 29 Oct 2025 | [OpenAI gpt-oss-safeguard](https://ollama.com/blog/gpt-oss-safeguard) | Safety-classification models, Apache-2.0. |
| 28 Oct 2025 | [MiniMax M2](https://ollama.com/blog/minimax-m2) | Coding/agent model on Ollama cloud. |
| 23 Oct 2025 | [NVIDIA DGX Spark performance](https://ollama.com/blog/nvidia-spark-performance) | Measured numbers on launch-day hardware. |
| 16 Oct 2025 | [New coding models & integrations](https://ollama.com/blog/coding-models) | GLM-4.6, Qwen3-Coder on cloud; faster local tool calling. |
| 14 Oct 2025 | [Qwen3-VL](https://ollama.com/blog/qwen3-vl) | Same-week vision-language model drop. |
| 13 Oct 2025 | [NVIDIA DGX Spark](https://ollama.com/blog/nvidia-spark) | Hardware partnership, “fast out of the box.” |
| 5 Aug 2025 | [OpenAI gpt-oss](https://ollama.com/blog/gpt-oss) | Partner post for a major open-weight release. |

Older 2023–2024 model and tutorial posts (Llama 2/3/3.2, Gemma 2, Granite, Code Llama, Obsidian, client-side RAG) follow the same pattern and are omitted here.

**How they work, distilled:**

1. One local server that speaks the APIs people already use (OpenAI, later Anthropic).
2. A public model library with a one-line `ollama run` / `pull` for each tag.
3. Official Python/JS libraries and docs updated in the same post as the feature.
4. A short public blog post the day a feature or a notable model ships, plus a changelog.
5. Integrations with the tools developers already have open (Claude Code, Codex, Continue, Claude Desktop).
6. Fast path on Apple Silicon (now MLX) without dropping GGUF/llama.cpp compatibility.
7. Cloud as an optional overflow, not the default identity.

---

## 2. What Quenderin has today

Quenderin is a **local/on-device LLM app**: native SwiftUI iOS + macOS (`apple/QuenderinKit`, llama.cpp C API / Metal), Kotlin/Compose Android (`android/quenderin-core`, JNI to llama.cpp, optional Vulkan), and a TypeScript CLI + Electron dashboard (`node-llama-cpp`). Shared GGUF catalogs and parity checks live in `shared/`. Site: [quenderin.org](https://quenderin.org). License: MIT (`LICENSE`). Positioning: “AI that works with no signal and never leaves your phone/Mac” (`docs/PRODUCT.md`).

| Area | Today | Evidence |
|---|---|---|
| Runtime | llama.cpp / GGUF on Apple and Android; `node-llama-cpp` on desktop. Metal on Apple; optional Vulkan on Android. No MLX engine in production (recorded as an unadopted candidate). | `apple/QuenderinKit/Sources/QuenderinKit/LlamaEngine.swift`, `android/quenderin-core/.../LlamaEngine.kt`, `package.json` (`node-llama-cpp`), `CHANGELOG.md` (MAX/MLX “unadopted”), `docs/NPU_NEURAL_ENGINE.md` |
| Model library / catalog | 28 pinned text models, RAM-aware auto-pick, hash-pinned resumable downloads, Hugging Face search, hourly “latest releases” snapshot on the site. | `FEATURES.md` §1, `shared/model-catalog.json`, `website/models.html` (live), `docs/MODEL_CATALOG_FRESHNESS.md` |
| Server / API | Desktop dashboard is a **custom** localhost REST + WebSocket API (`/api/models`, `/api/sessions`, chat over WS). **Not** OpenAI `/v1/chat/completions`. Apple “local command / server on this device” is a **loopback MCP tool desk**, not an inference API. Optional DeepSeek *cloud* chat uses `api.deepseek.com/chat/completions`. Optional “Step 5” talks to a user-configured CUDA host. | `docs/API.md`, `src/app.ts`, `apple/.../OnDeviceJob.swift` (`LocalToolDesk`, `LocalServer`), `DeepSeekProvider.swift`, `scripts/run_step5_backend.py` |
| Tool calling | Yes, but bounded and custom: desktop XML `<tool_call>` loop (`calculator`, `datetime`, `system_info`, max 3 calls). Apple/Android have `AgentTool` + MCP local servers + a governed capability agent (approval, ledger, undo). Not an OpenAI-style streaming tools API. | `FEATURES.md` §5, `src/services/tools/handlers.ts`, `apple/.../AgentTool.swift`, `OnDeviceJob.swift` |
| Structured outputs | **Partial, internal.** GBNF grammars constrain agent decisions (`{"tool","input"}` / plan / answer) in `LlamaEngine`. No user-facing JSON-schema / `format` parameter. | `apple/.../AgentDecisionGrammar.swift`, `LlamaEngine.swift` (grammar sampler ~705–711) |
| Vision | **Partial, source.** MiniCPM-V and Nemotron Super VL installers + `NativeVisionEngine` exist. Main chat still says “images: vision not available yet.” Full-weight inference unverified. | `VisionEngine.swift`, `VisionModels.swift`, `ChatView.swift:499`, `CHANGELOG.md` / README October integrations |
| Thinking toggle | **Partial, inverted.** Local reasoning models (Qwen3, DeepSeek-R1 templates) default to thinking **OFF** (empty `<think>` closed in the prompt). `StopSequenceScanner` can stop at `</think>`. No Settings toggle to turn thinking on, and no separated thinking stream in local chat. DeepSeek *cloud* UI does have a Thinking picker. | `LlamaEngine.swift:385–430`, `StopSequenceScanner.swift`, `DeepSeekView.swift` |
| Embeddings | **No** embedding models, no `/api/embed` or `/v1/embeddings`. “Embed” hits in the tree are unrelated (Hex `--embedded`, hardware tier). Hy-Memory is proposal-and-approve facts, not vector RAG. | search of `apple/`, `src/`, `android/quenderin-core` for `llama_get_embeddings` / embed API: no hits; `HyMemory.swift` |
| Context length | Desktop Settings allowlist 512–8192 (default 2048). Apple/Android **auto-size** `n_ctx` from app-memory budget and model footprint (cap 8192); no user slider. | `FEATURES.md` §8, `docs/API.md` (`settings_update` / `contextSize`), `ContextWindow.swift` |
| Web search | **No** product web-search tool. `PRODUCT.md` puts “any cloud call” out of the mobile product (DeepSeek and Step 5 are explicit, consented exceptions). | `docs/PRODUCT.md`, no `web_search` tool in `FEATURES.md` / agent tools |
| Image generation | **Partial, source.** Isolated `stable-diffusion.cpp` ABI, FLUX 3 / MOSS / Kromoss presets, CLI + Apple + Android wiring. `inferenceVerified: false`. | `FEATURES.md` §11, `native/diffusion`, `ImageGenerationEngine.swift`, `CHANGELOG.md` 22 Nov 2026 |
| Speech | **STT / dictation, not TTS.** Hex + `transcribe.cpp`, 20 ASR presets + Silero VAD, Apple Speech, `quenderin voice`. Opposite of Ollama’s Oct 2026 Phonon TTS. Unverified on device. | `FEATURES.md` §12, `native/speech`, `NativeSpeechEngine.swift` |
| KV / prefix cache | Chat **KV-cache reuse** across turns (decode only the new suffix); q8_0 KV on tight devices. Not Ollama’s cross-request prefix cache + routing write-up, but the on-device equivalent for single-session chat is there. | `STATUS.md` (KVCacheReuse), `KVCacheReuse.swift`, `KVCachePolicy.swift`, `docs/MOBILE_PERFORMANCE_101.md` |
| Model lifecycle / scheduling | Idle auto-unload (30 min desktop), load dedup, exclusive memory leases, RAM-fit gates, thermal thread shed. Not a multi-GPU datacenter scheduler. | `FEATURES.md` §§2, 7; `SpecialistInferenceLease` |
| App UX | Streaming chat, Markdown, history, export, model picker, personas (desktop), text/PDF attach (extracted at attach time), Settings, telemetry bar (tok/s, TTFT). | `README.md`, `FEATURES.md` §§2–3, `ChatView.swift`, `DocumentTextExtractor.swift` |
| CLI | `quenderin models`, `download`, `chat` (REPL + pipe), Mac `do` / `undo` / `capabilities`. Not as tight as `ollama run llama3 "…"`. | `README.md`, `src/commands/` |
| Docker | Yes, dashboard image on port 3000, bind to localhost, token auth. | `Dockerfile` |
| Release notes / blog / docs | Live blog (~18 posts, Jul–Nov 2026), changelog, models page, 30-page docs portal compiled from the repo. Tone is careful and source-vs-store honest, closer to an engineering journal than Ollama’s “now available” cadence. Bursts in July, October, and 22 Nov; not a steady weekly feature/model drumbeat. | [quenderin.org/blog.html](https://quenderin.org/blog.html), `website/changelog.html`, `website/docs/`, `CHANGELOG.md` |
| Client libraries | No official Python/JS SDK in the Ollama sense. Integration is the custom REST/WS API, the TS CLI, and native kits. | `docs/API.md`, `package.json` |

---

## 3. Gap map

Effort: **S** = days, mostly wiring or copy, existing primitives; **M** = a focused feature slice, new API surface or UI, still on the current engine; **L** = new runtime, new model class, or a product-identity change.

### A. Product features

| Ollama feature | Quenderin? | Evidence | Effort | Platform | Value / fit |
|---|---|---|---|---|---|
| GGUF / llama.cpp runtime | **Yes** | `LlamaEngine.swift`, `LlamaEngine.kt`, `node-llama-cpp` | — | all | Already the core. Keep it. |
| Model library + one-command pull | **Partial** | 28-model catalog + site models page + `quenderin download`; no `ollama run`-style tags or per-model pages | S (pages + CLI sugar) | site, CLI, all apps | High. You already curate and hash-pin; the missing piece is presentation and a one-liner. |
| Device-aware pick, integrity, resume | **Yes** (stronger than Ollama’s app story) | `FEATURES.md` §1, §6; `ModelIntegrity`, `AutomaticModelSelection` | — | all | Keep leading with this. |
| OpenAI-compatible local API | **No** (custom `/api/*` + WS only) | `docs/API.md`, `src/app.ts` | S–M | Mac, desktop; later Android? iOS loopback only if needed | **Highest-leverage Ollama move.** Existing tools (OpenAI SDK, Codex, Continue, many apps) just change `base_url`. Fits on-device if it binds loopback, stays off by default or behind a Mac setting, and never phones home. |
| Anthropic / Claude Code / Codex / Claude Desktop gateways | **No** | no Anthropic compat in tree | M (after OpenAI API) | Mac, desktop | High for developers, once `/v1` exists. Not needed on iPhone. |
| `ollama launch` one-command tool setup | **No** | CLI is `chat` / `do` | M | Mac, desktop | Nice after the API exists; not the first step. |
| Official Python/JS libraries | **No** | — | S (document “use the OpenAI SDK”) then M (thin wrapper) | site, docs | High, almost free once `/v1` ships. |
| Thinking on/off + visible thinking | **Partial** (forced off locally; cloud DeepSeek has a picker) | `LlamaEngine.swift:385–430`, `DeepSeekView.swift` | **S** | iOS, Mac, Android, API | **Easy, on-device, high value.** Machinery already parses `<think>`. |
| Streaming OpenAI-style tool calling | **Partial** (custom XML / AgentTool / MCP, not the API) | `FEATURES.md` §5, `AgentTool.swift` | M | Mac/desktop API first; apps later | High for agents; mobile tools should stay bounded (`PRODUCT.md`). |
| Structured outputs (JSON schema) | **Partial** (GBNF for the agent only) | `AgentDecisionGrammar.swift`, `LlamaEngine` grammar sampler | **S** | API + Settings; all engines that already take GBNF | High for anyone building on the local API; easy because the sampler is there. |
| Vision in the main chat composer | **Partial** (separate workflow; chat rejects images) | `VisionEngine.swift`, `ChatView.swift:499`; inference unverified | S–M to wire; L to call it “ready” | iOS, Mac, Android, site | High UX, but do not advertise until a real on-device pass is verified. |
| File / PDF chat | **Yes** (text/PDF extracted at attach time) | `DocumentTextExtractor`, `ChatView.swift` | — / S to raise context for long PDFs | all | Already there; pair with a context slider. |
| Context-length control | **Partial** (desktop slider; mobile auto-only, cap 8192) | `FEATURES.md` §8, `ContextWindow.swift` | **S** | iOS, Mac, Android (with memory warning) | High on Mac; on iPhone keep auto default and offer a cautious override. |
| Embedding models + `/api/embed` | **No** | no embed path in engines | M | Mac/desktop API, later apps | Medium. Enables local RAG on notes already on the device. Fits the privacy thesis. |
| Web search / fetch API | **No** | `PRODUCT.md` (no cloud by default) | M, and only as explicit opt-in | optional, not default | Useful, but it is a **cloud call**. Do not copy as a default. If ever, same consent pattern as DeepSeek. |
| Cloud models / pricing plans | **No** (by design) | `docs/PRODUCT.md`, README privacy | L + identity change | — | **Out.** “Nothing you type leaves the device” is the wedge. DeepSeek/Step 5 already cover consented exceptions. |
| Image generation | **Partial** (source, unverified) | `FEATURES.md` §11, `native/diffusion` | M–L to verify and ship | Mac first, then iOS/Android if memory allows | Nice, and you are closer than a green-field build. Not “easy” until inference is measured. |
| Speech TTS | **No** (you have STT) | `FEATURES.md` §12 vs Ollama Phonon | L | Mac first | Complementary, not a copy of what you already built. Lower priority than the API/thinking work. |
| Speech STT / dictation | **Yes** (source, unverified) | `native/speech`, `NativeSpeechEngine` | M to verify | all | You are ahead of Ollama here. Finish and show it, don’t rebuild. |
| MLX engine / MTP / NVFP4 | **No** (candidate only) | `CHANGELOG.md` 26 Oct 2026, `docs/NPU_NEURAL_ENGINE.md` | **L** | Mac, maybe iOS | Real speed prize on Apple Silicon; not “half we can easily implement.” Stay on llama.cpp until a deliberate spike. |
| Prefix cache for long agents | **Partial** (session KV reuse) | `KVCacheReuse.swift` | M to extend / measure | all, especially Mac agent | You already did the important on-device part. Cross-session or multi-tool prefix stability is a later polish. |
| Model scheduling / OOM discipline | **Partial** (leases, fit gates, idle unload, thermals) | `FEATURES.md` §7, `STATUS.md` | S to expose status in UI | all | Already strong; a clearer “model loaded / unloaded / would OOM” surface would match Ollama’s honesty on memory. |
| Decision models (Jev / Clef) | **No** | — | L | — | Niche. Skip unless a typed-decision use shows up in the agent. |
| Docker | **Yes** | `Dockerfile` | S (docs/example polish) | desktop / self-host | Already there. |
| Performance write-ups with numbers | **Partial** | host/sim numbers in `STATUS.md` / `docs/BENCH_BASELINE.md`; physical-phone numbers still flagged as missing | S once you have device numbers | site | Ollama-style posts need measured tok/s, not estimates. |

### B. How they work (practice, not engine features)

| Ollama practice | Quenderin? | Evidence | Effort | Where | Value |
|---|---|---|---|---|---|
| Short “now available” blog the day a feature or model ships | **Partial** — blog exists, tone is longer and more hedged; cadence is bursty | [quenderin.org/blog.html](https://quenderin.org/blog.html) | **S** | site (`website/blog-*.html`) | High. Keep the honesty about store vs source; add a short announcement layer on top. |
| Per-model library pages (`ollama.com/library/…`) with a run/download line, tags, examples | **Partial** — one models table + hourly snapshot, no per-model page | [quenderin.org/models.html](https://quenderin.org/models.html) | **S** | site | High, and you already have the catalog data. |
| Changelog / release notes tied to store versions | **Partial** — `CHANGELOG.md` + site changelog; store version sometimes lags the post | `CHANGELOG.md`, `website/changelog.html`, 9 Nov blog (“not a store build”) | **S** | site, App Store “What’s New” | High. Always label **store 0.6.x** vs **source**. |
| Docs + official client snippets in the same announcement | **Partial** — 30-page docs portal, no SDK snippets | [quenderin.org/docs/](https://quenderin.org/docs/) | **S** after `/v1` | site, docs | High. |
| Ecosystem integrations announced as products | **No** | — | M after API | Mac, site | High for developers. |
| Same-week model-drop posts for notable GGUF releases | **Partial** — hourly discovery list, few “X is in Quenderin” posts | `models.html` snapshot; Oct 12/16/18 posts | **S** | site, catalog | Medium-high. You already ingest releases; write the short card. |
| Community / libraries / Docker as on-ramps | **Partial** (Docker + MIT repo; no SDK) | `Dockerfile`, `README.md` | S | GitHub, site | Medium. |

---

## 4. First batch — the easy half, ordered

These are the items that are **S (or S with a thin M)**, fit an on-device app, and do not break `docs/PRODUCT.md`. They are the “half we can easily implement.” No engineering in this note; each item is a short spec for a later yes from Albert.

### 1. Thinking toggle (S) — iOS, Mac, Android, then API

**Why first:** the engine already knows how to turn thinking off (`LlamaEngine.swift` closes an empty `<think>` for Qwen3 / R1 templates; default OFF). `StopSequenceScanner` already stops at `</think>`. Ollama’s 30 May 2025 post is exactly this UX, and you already have the DeepSeek cloud picker as a visual reference (`DeepSeekView.swift`).

**Spec:** A Settings (and/or chat) control, off by default: Off / On / Hide thinking (answer only). When On, stream thinking in a collapsed “Thinking” disclosure, then the answer. When Off, keep today’s prompt behaviour. Only show the control for models whose template has `enable_thinking` or `<think>`. Mirror on Android. Once the local API exists, add a `think` boolean like Ollama. No new model, no new runtime.

### 2. Loopback OpenAI-compatible API on Mac (S–M) — Mac app + desktop server

**Why:** this is how Ollama became the default local backend. Almost every tool already speaks `/v1/chat/completions`.

**Spec:** On Mac (and the desktop dashboard), an opt-in “Local API” setting. Bind **127.0.0.1 only**. Endpoints for v1: `GET /v1/models`, `POST /v1/chat/completions` (streaming SSE). Use the already-loaded model; if none, return a clear error. A dummy API key is accepted and ignored. No LAN bind, no account, no cloud. iPhone stays a client of “a server on this device” if you ever need it; do not ship a listening server in the App Store iOS build unless legal/review is checked. Document one snippet: `OpenAI(base_url="http://127.0.0.1:<port>/v1", api_key="quenderin")`. Out of scope for v1: tools, vision, audio, embeddings (those are later rows).

### 3. Official client story = the OpenAI SDK (S) — docs / site

**Spec:** Do not start a new Python package. Add a short docs page and a blog “now available” once #2 is real: curl, Python `openai`, and JS `openai` examples, plus a note that Codex / Continue / similar only need the base URL. Update the Python/JS examples whenever a later API feature ships (Ollama’s library cadence).

### 4. User-facing structured outputs (S) — API first, then a small UI

**Spec:** Expose the existing GBNF path as `response_format` / `format` on `/v1/chat/completions` (JSON schema or `{ "type": "json_object" }`). Convert schema → GBNF or use llama.cpp’s existing JSON-schema support if already linked. Temperature 0 recommended in the docs. Optional later: an advanced “Reply as JSON” toggle in Settings. Agent grammars stay as they are. Skip models already documented as grammar-incapable (Beam, Jais comments in `LlamaEngine.swift`).

### 5. Context-length control on Apple (and Android) (S)

**Spec:** Keep auto `n_ctx` as the default (`ContextWindow.swift`). Add a Settings control: Auto / 2k / 4k / 8k, with the same “uses more memory” warning Ollama’s app uses. On iPhone, refuse or warn hard when the pick would exceed the jetsam-aware budget; never crash. Desktop already has the allowlist — keep it, and consider one higher step on Mac only (e.g. 16k) with an explicit memory warning, not as a silent default.

### 6. Per-model library pages + announcement cadence (S) — site only

**Spec:** Generate one page per curated catalog entry from `shared/model-catalog.json` (name, size, RAM estimate, quant, license, what it’s good for, “Download in the app” / `quenderin download <id>`). Keep the hourly “latest releases” list, clearly labelled untested. For store releases and for each *verified* catalog addition, publish a short Ollama-style post (title, date, one hook paragraph, get-started, link to the model page). Keep the current honesty line: store version vs source vs `inferenceVerified`. Suggested rhythm: one short post per App Store version, plus a same-week note when a notable model is actually runnable in the app — not a post for every snapshot row.

### 7. CLI sugar: `quenderin run` (S) — desktop CLI

**Spec:** A thin alias: `quenderin run <model-id> ["prompt"]` downloads if needed, then chats or prints one answer (pipe-friendly). Optional later: `quenderin run <model> --think`. This is presentation, not a new engine.

### 8. Vision in the chat attach path — wire only, gated (S to wire; ship only after a verified device pass)

**Spec:** When a vision runtime is present and a VL model is installed, allow image attach in the main composer and send the image through `NativeVisionEngine` instead of the “vision not available yet” help string (`ChatView.swift:499`). If the runtime or weights are missing, keep today’s honest rejection. Do **not** call this done in store copy until a physical-device (or at least simulator) full-weight pass is recorded. This is the one item in the batch that can slip from S to M; if time is tight, leave it immediately after the first seven.

### Deliberately not in the first batch

- **MLX / MTP** — right idea for Apple speed, wrong size for “easy.”
- **TTS (Phonon-style)** — new model class; you already invested in STT. Revisit after STT is verified.
- **Web search and Ollama cloud** — conflict with the offline/private wedge unless they stay strictly opt-in and clearly separate, like DeepSeek.
- **Jev decision models, Fly.io, funding/pricing posts** — not on-device product work.
- **Image generation and specialist October models** — already in source; the work left is verification, not cloning Ollama.
- **Custom Python library, Anthropic API, `launch` integrations** — natural second batch, after `/v1` exists.
- **Embeddings / local RAG** — good second-batch, medium effort, on-thesis.

---

## 5. What to copy, and what not to

Copy Ollama’s **shape**: a loopback API people already know, a toggle for thinking, schema-constrained output, a context control, a model page, and a short public “now available” note.

Do not copy Ollama’s **cloud identity**, default web search, or “we run the frontier model for you” pricing. Quenderin’s wedge is the opposite, and `docs/PRODUCT.md` is explicit about it.

You already beat Ollama in a few places that should stay on the homepage: native iPhone and Android apps, jetsam-aware model picking, hash-pinned downloads, thermal governors, and a governed local agent with approval and undo. The first batch is about making that stack as *easy to hook into and as clearly announced* as Ollama, not about becoming a desktop model runner with a cloud upsell.

---

## Paths

- This file: `/workspace/quenderin-ollama-20261126/gap-map.md`
- Suggested long-term copy in Albert’s repo: `docs/research/ollama-gap-map-20261126.md` in `/workspace/quenderin-v063` (github.com/alikatgh/quenderin). Not committed from this pass.
