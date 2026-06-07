# Quenderin Architecture

The concepts under the code — what the pieces *are* and how they fit. For the
how-to (linking llama.cpp, deploying), see `QuenderinKit/INTEGRATION.md` and
`ROADMAP.md`. For the module-by-module catalog, see `QuenderinKit/README.md`.

## The thesis

**Offline, on-device AI.** The language model runs on the phone in the user's
hand — not in a data center. After a one-time model download there are no network
calls, no API keys, no accounts, no telemetry. The whole architecture exists to
make that real, reliable, and usable by a non-technical person.

## The two layers you must never conflate

The single most common confusion. There are **two** completely different things:

| | **The engine** (llama.cpp) | **The model** (GGUF weights) |
|---|---|---|
| What it is | A C/C++ program that runs models | A data file: the trained weights |
| Size | A few MB of compiled code | 0.4 – 4.7 GB |
| How it reaches the phone | **Compiled into the app** → ships via the App Store | **Downloaded in-app**, over Wi-Fi |
| Does the user see it? | No — it's invisible, baked in | Yes — it's "the download" |
| Who provides it | The developer, at build time | The user picks one; the app fetches it |

**Analogy:** llama.cpp is the *music player*; the model is the *songs*. You
install the player once (engine included), then download songs into it. Users
never "download the engine" — they download content for it.

So: a user installs Quenderin (small — app + engine), then the app downloads **one
model** (the gigabytes). That model download is what the M3 "offline-ready"
machinery is all about.

## The pieces, bottom to top

### ggml
The low-level tensor math library (by Georgi Gerganov, org `ggml-org`). Does the
actual numeric work, with hardware backends: CPU SIMD, Apple **Metal** (GPU),
CUDA, Vulkan. llama.cpp is built on it.

### llama.cpp
The inference **engine** — open-source C/C++ that loads a model and generates
text efficiently on consumer hardware. It's the de facto standard for local LLMs
(Ollama, LM Studio, Jan, GPT4All all build on it). Ships **inside** the app.

### GGUF + quantization
A model's weights are normally 16-bit floats (an 8B model ≈ 16 GB — too big for a
phone). **Quantization** squeezes each weight to ~4 bits (`Q4_K_M`) or fewer
(`Q2_K`), shrinking it to ~4.5 GB with little quality loss. The quantized file
format is **`.gguf`** — that's exactly what the user downloads. Quenderin's
catalog (`ModelCatalog`) lists four GGUF builds from 0.4 to 4.7 GB.

### LlamaEngine (the Swift adapter)
llama.cpp stays C/C++; `LlamaEngine.swift` is the ~30-line-loop Swift wrapper
that calls its C API (tokenize → decode → sample → detokenize → stream). The heavy
lifting is all in the C++; this just steers it. (Android will get a Kotlin/JNI
adapter over the *same* C++.)

### The seams: `InferenceEngine` and `ModelDownloader`
Two protocols the rest of the app depends on, never the concretes:
- `InferenceEngine` — anything that can load a model and stream tokens.
  Conformers: `LlamaEngine` (real), `MockInferenceEngine` (canned),
  `ScriptedInferenceEngine` (deterministic, for tests).
- `ModelDownloader` — anything that can fetch a model.
  Conformers: `URLSessionModelDownloader`, `BackgroundModelDownloader` (survives
  app suspension), `MockModelDownloader`.

These seams are why the entire app runs and is **fully tested today on mocks**,
with no llama.cpp and no model file — and why swapping in the real engine is a
two-line change in `QuenderinApp.init()`.

### QuenderinKit (the brain)
The pure-Swift package with everything above the engine: hardware probe, model
catalog + recommendation, memory/disk fitness, the download + offline-readiness
machinery, onboarding/chat state, and the agent loop. Compiles + unit-tests on a
Mac (no simulator). See `QuenderinKit/README.md` for the full module list.

## The stack

```
Quenderin (the app the user installs)
  └─ QuenderinApp        SwiftUI @main → RootView (onboarding → chat)
      └─ QuenderinKit    the brain: probe, recommend, download, readiness, chat, agent
          ├─ InferenceEngine seam ── LlamaEngine ──┐
          └─ ModelDownloader seam                  │
                                                   ▼
                                            llama.cpp (C/C++ engine)   ← compiled in
                                                   ▼
                                              ggml (tensor math, Metal GPU)
                                                   ▲
                                          a .gguf model file            ← downloaded in-app
```

**In plain terms:** llama.cpp is the part that actually *thinks*. Everything in
QuenderinKit is the scaffolding that makes that engine usable by a real person —
picking a model that fits their device, downloading it survivably, proving it's
ready before they go offline, and turning it into a chat and a tool-using agent.

## The user lifecycle

1. **Install** Quenderin (App Store) — small; engine baked in.
2. **Probe** — the app reads RAM/chip and recommends the best model that fits.
3. **Download** — one GGUF, over Wi-Fi, resumable in the background.
4. **Ready check** — a verifiable "✅ safe to go offline" (downloaded + loads).
5. **Use** — chat or agent, 100% on-device. No further network, ever.

## One engine, three clients

The same llama.cpp/ggml core powers every platform; only the thin adapter differs:

| Platform | Adapter | Status |
|----------|---------|--------|
| Desktop (Electron/TS) | `node-llama-cpp` (Node binding) | shipping prototype |
| iOS (Swift) | `LlamaEngine` (Swift → C API) | built; needs llama.cpp linked on-device |
| Android (Kotlin) | `LlamaEngine` (Kotlin → JNI → C++) | **brain + UI built on mock** (M1–M2): core tested (29 kotlinc checks), JNI bridge (`jni/llama_jni.cpp`) + Compose app (`android/app`) written; needs llama.cpp linked on-device (same cliff as iOS) |

The durable, portable assets — the model catalog/recommendation logic and the
symbolic protocols — are shared so all three clients agree on what to run.

## See also

- `QuenderinKit/INTEGRATION.md` — how to link llama.cpp (xcframework) + run on device.
- `QuenderinKit/README.md` — the module catalog.
- `ROADMAP.md` — milestones (M1 onboarding → M4 agent core) and what's left.
