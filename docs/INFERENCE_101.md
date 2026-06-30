# Inference 101 — for Quenderin specifically

> Goal of this doc: close the gap between *"I shipped this"* and *"I understand this."* By the end you
> should be able to **derive Quenderin's mobile speed ceiling from scratch** and explain every line of
> the real decode loop. It's grounded in your actual code (real files + line numbers) and your actual
> model catalog — not generic theory. Read it twice; the second time, open the cited files alongside.

---

## 0. The one equation (memorize this — everything else hangs off it)

Generating **one token** requires a forward pass that reads **~every weight in the model from memory, once.** So:

```
tokens/sec  ≈   memory_bandwidth  ÷  bytes_read_per_token
                                       └─ ≈ the model's on-disk size (the weights)
```

That's the whole story of why phones are slow at this. It is **not** about how fast the chip can multiply (FLOPs) — it's about how fast it can *read the weights out of RAM*. This is what "decode is **memory-bandwidth-bound**" means, and it's the sentence you put in your email to Georgi.

**Work it with your own catalog** (`shared/model-catalog.json`):

| Model | Weights (Q4) | Phone RAM bandwidth | Ceiling = BW ÷ weights | Real-world (~30–50%) |
|---|---|---|---|---|
| Llama 3.2 1B | ~0.8 GB | ~60 GB/s (LPDDR5) | ~75 tok/s | **~20** (matches `REALITY.md` A16) |
| Qwen3 4B | ~2.4 GB | ~60 GB/s | ~25 tok/s | **~10–13** (matches `REALITY.md`) |
| Qwen3 14B | ~9 GB | ~60 GB/s | ~7 tok/s | ~3–5 (and barely fits) |
| (same 4B on an M-series Mac) | ~2.4 GB | ~200–400 GB/s | ~80–160 tok/s | **~157–177** (your `verify-llama-link.sh`) |

Two things fall out immediately:
1. **A Mac is fast only because it has 3–6× the memory bandwidth** — *not* because its CPU is smarter. Same model, same code; the bandwidth column is the whole difference. That's why your Mac/sim numbers are a *ceiling*, not a phone result.
2. **The biggest lever to go faster is to read fewer bytes per token** — i.e. a smaller or more-quantized model. Everything else is at the margins.

Real-world lands at ~30–50% of the ceiling because you never perfectly saturate bandwidth (overhead, the KV cache also gets read, the chip isn't at max clock). Keep that "efficiency factor" in mind — the equation gives you the **upper bound**.

---

## 1. What a model file actually is

A `.gguf` file is just **the weights** (billions of numbers) + a header of metadata (architecture, tokenizer, etc.). Two facts that matter:

- **Quantization** = how many bits per weight. `Q4_K_M` (your default) ≈ 4.5 bits/weight instead of 16. That's why a 4-billion-param model is ~2.4 GB instead of ~8 GB — and, per the equation above, **why it's ~3× faster to decode.** The cost is a small quality drop. Quant is the dial between speed/size and quality.
- The first 4 bytes are the magic string `GGUF`. That's literally what `ModelIntegrity.verify` (`src/services/modelIntegrity.ts`, `apple/.../ModelIntegrity.swift`) checks before trusting a download — a corrupted/MITM'd file fails the magic check or the sha256.

The catalog (`ModelCatalog.swift` / `src/constants.ts` / Android `ModelCatalog.kt`, kept in sync by `scripts/check_catalog_parity.py`) is just a table of these files + their sizes + RAM needs.

---

## 2. The two phases — and why GPU helps only one

Every request has two phases, and they have **opposite** performance characters:

| Phase | What it does | Bound by | Does the GPU/Metal help? |
|---|---|---|---|
| **Prefill** | Reads your prompt, fills the KV cache | **Compute** (all prompt tokens in parallel) | **Yes** — lots of parallel math |
| **Decode** | Generates the reply, one token at a time | **Memory bandwidth** (one token at a time, reads all weights each time) | **Barely** — it's waiting on RAM, not math |

This is the single most important thing most people get wrong. It's why:
- `LlamaEngine.swift:131` sets `n_gpu_layers = 999` (offload everything to Metal) — it helps prefill and is free on Apple's unified memory.
- But on Android, `GpuOffloadPlanner` is **conservative** — because for a single user's *decode*, Vulkan offload often doesn't help (decode is bandwidth-bound, and the GPU shares the same RAM bus), so it only offloads where it's been shown to win.

---

## 3. The generation loop, line by line (`LlamaEngine.swift:runGeneration`)

This ~40-line function is the entire product. Open `apple/QuenderinKit/Sources/QuenderinKit/LlamaEngine.swift:196` and read it with this map:

```
1) tokenize(prompt)            → text becomes a list of integer token ids        (:210)
2) build a sampler chain       → top-p → temperature → distribution               (:217-220)
3) KV-reuse plan               → decode ONLY the tokens not already cached        (:236)   ← §4
4) decode(prompt tokens)       → llama_decode(...) fills the KV cache (prefill)    (:242)
5) loop until maxTokens or EOG:
     - every 32 tokens, ask the thermal governor for a new thread count           (:257-260) ← §6
     - llama_sampler_sample(...) → pick the next token                            (:261)
     - if it's the end-of-generation token, stop                                  (:262)
     - turn the token back into text, yield it to the UI                          (:264-265)
     - decode(that one token) → advances the KV cache by one                      (:269)
     - append it to our token mirror                                              (:273)
```

That's it. "An LLM generating text" is: **sample one token, feed it back in, repeat.** `llama_decode` (:229) is the one expensive call — it's the forward pass from §0 that reads all the weights. Everything else (sampling, detokenizing) is cheap. So the loop runs at exactly the tok/s the equation predicts.

> **Sampling**, briefly (`:217-220`): the model outputs a probability for *every* word in its vocabulary. `temperature` flattens/sharpens those probabilities (higher = more random), `top-p` keeps only the most-likely set, and `dist` rolls the dice among them. That's "creativity" — it's just how you pick from the probability list.

---

## 4. The KV cache — why context costs memory and why reuse matters

When the model processes tokens, it stores intermediate results (the "keys" and "values") so it doesn't recompute them every step. This is the **KV cache**, and it has two consequences you've already engineered around:

- **It grows with context length** and sits *on top of* the model weights in RAM. A fixed huge `n_ctx` can push a memory-tight phone over its budget and get the app jetsam-killed. So `ContextWindow.recommend(...)` (`:149`) sizes `n_ctx` from the **real app-memory budget − the model's footprint**. A 1B gets a big context; a 7B on the same phone gets a tight one.
- **Quantizing the cache** (`KVCachePolicy.recommend`, `:146`) to `q8_0` roughly halves its per-token memory → the cache-aware `n_ctx` turns that into ~2× the usable context, near-losslessly.
- **Reuse** (`KVCacheReuse.plan`, `:236`): on turn 2 of a chat, the prompt is "turn-1 + new stuff." Re-prefilling the whole thing every turn would make replies get slower as the conversation grows. So Quenderin decodes **only the new suffix** and keeps the rest cached — time-to-first-token stays flat. (Fail-safe: any divergence wipes the cache and reprefills — correct, just no speedup.)

---

## 5. Threads — why "use all the cores" is wrong here

`ThreadPlanner.swift` (15 lines — read it) targets the **performance cores only**, not all cores. Why? Two reasons, both from §0:

1. On a phone's big.LITTLE / P+E core layout, scheduling matmul-heavy decode onto the slow **efficiency cores bottlenecks the fast ones and adds heat** — net negative.
2. Because decode is **bandwidth-bound**, once you have enough threads to saturate the memory bus, **more threads do nothing but generate heat.** You can't multiply your way past a memory wall.

So "more threads = faster" is false past a small number. This is set at `LlamaEngine.swift:165` (`n_threads`) and — crucially — *re-tuned during generation*, which brings us to the ceiling.

---

## 6. The ceiling you emailed Georgi about — now derive it yourself

Put §0 and §5 together:

- **Sustained speed is capped by bandwidth** (§0), and a phone's effective bandwidth **drops as it heats** (thermal throttling cuts clocks *and* memory speed). Your `REALITY.md` measured 10–44% loss on multi-minute runs. So a long agent loop doesn't run at the cold-start tok/s — it decays toward a hot-steady-state.
- Quenderin's answer is the **in-flight thermal governor** (`LlamaEngine.swift:251-260` + `ThermalMonitor.swift`): every 32 tokens it reads the thermal level and, if it changed, calls `llama_set_n_threads(...)` to **shed threads as the chip heats** — trading peak tok/s for a *sustainable* rate instead of spiking and getting throttled (or jetsam-killed). That's exactly "power-aware decode."

Now you can answer your own email. **Are there llama.cpp-level levers, or is the ceiling fundamental?**
- The **bandwidth + thermal ceiling is largely fundamental** for a given model on a given phone — thread/batch scheduling can't beat a memory wall, and you're already self-throttling optimally.
- The levers that *actually* move it, in order of impact:
  1. **Smaller / more-quantized model** — fewer bytes/token (direct, from §0).
  2. **KV-cache quant** — fewer bytes read at long context (you do this).
  3. **Speculative decoding** — a tiny "draft" model proposes several tokens, the big model *verifies* them in one pass. This is the one trick that beats the single-stream bandwidth wall — memory permitting. **This is the thing to ask Georgi about next.**
- `batch scheduling` is a non-lever here: it helps throughput across *many parallel users*, not one person's reply.

If you can explain that paragraph from memory, the gap is closed.

---

## 7. Where each concept lives (the code map)

| Concept | Desktop (TS) | iOS (Swift) | Android (Kotlin/JNI) |
|---|---|---|---|
| The decode loop | `node-llama-cpp` via `src/services/llm.service.ts` | `LlamaEngine.swift:196` | `android/jni/llama_jni.cpp` |
| Context (`n_ctx`) sizing | hardware tier in `health.ts` | `ContextWindow.swift` | `ContextWindow.kt` |
| KV cache quant / reuse | (engine-managed) | `KVCachePolicy` / `KVCacheReuse.swift` | core twins |
| Thread count | hardware profile | `ThreadPlanner.swift` | `ThreadPlanner.kt` |
| Thermal governor | n/a (desktop = plugged in) | `ThermalMonitor` + governor in `LlamaEngine` | `ThermalMonitor.kt` + JNI loop |
| GPU offload | — | `n_gpu_layers=999` (Metal) | `GpuOffloadPlanner.kt` (conservative) |
| Model integrity | `modelIntegrity.ts` | `ModelIntegrity.swift` | `ModelDownloadEngine` |

The desktop, iOS, and Android engines all implement the **same loop** — only the language and the device tuning differ. Read the Swift one (it's the clearest); the others will then make sense.

---

## 8. Prove it to yourself (do these, don't just nod)

1. **Run real inference** (5 min, your hardware): `apple/verify-llama-link.sh`. Watch it print tokens at ~160 tok/s on the Mac. That number *is* `bandwidth ÷ weights` for that tiny model.
2. **Predict before you measure:** a Qwen3 4B on a phone with ~50 GB/s and ~35% efficiency — what tok/s do you expect? (Answer: `50 ÷ 2.4 × 0.35 ≈ 7 tok/s`. Then check it against `REALITY.md`.)
3. **Explain, out loud, without notes:** why does Metal make prefill fast but not decode? (§2) Why does q8_0 KV cache buy you 2× context? (§4) Why does the governor *remove* threads when the phone is hot instead of adding them? (§5–6)
4. **The Georgi follow-up:** if speculative decoding 1.5–3×'s decode, what's the catch on a phone? (Answer: you need *both* the draft and the target model resident in memory at once — and phone memory is the tight constraint, §4.)

When #3 and #4 come out fluently, you don't just have the repo — you have the knowledge. That's the level where you stop needing me to draft the email.
