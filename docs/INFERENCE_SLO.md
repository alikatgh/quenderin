# Inference SLOs — local models must feel like a paid cloud service

_The owner's bar (2026-09-05): "run these models locally like if they were running cloud paid services."_
This file is the contract: what a cloud service gives the user, the number we hold ourselves to for the
same feeling on-device, how it is measured, and where we stand. A number without a measurement is a wish;
every target here has a harness (`scripts/bench_inference.sh`, the native smoke test, or a device run).

## Targets

| What the user feels | Cloud reference | On-device target | Measured by |
|---|---|---|---|
| **First token after tapping send** (short prompt, model already loaded) | 0.3–1 s | ≤ 0.5 s desktop, ≤ 1.0 s phone — **every** message, including the first after launch | `llama-smoketest --ttft cold\|warm` (fresh process); app: `GenerationPhase.loadingPrompt` → `.writing` |
| **First token, long prompt** (~1k tokens: attachment / long history) | 1–3 s | ≤ 3 s desktop, ≤ 8 s phone; never a crash | smoke Part 3 (chunked prefill), `REAL: prefill` tok/s |
| **Streaming speed** | 40–100 tok/s | ≥ 20 tok/s desktop (reading speed ×2), ≥ 10 tok/s phone for the model the selector recommends | `llama-bench tg128`, `REAL: decode` |
| **Smoothness** — no visible stall once text is flowing | none | no inter-token gap > 250 ms after the first token; UI writes ≤ 30/s (`StreamFlushGate`, both twins) | `StreamFlushGateTests` / CoreVerify; device run with per-token timestamps (todo: signposts) |
| **Sustained** — a two-minute reply doesn't turn to sludge | none | tg512 ≥ 0.8 × tg128; on phones the thermal governor sheds threads instead of stalling | `llama-bench tg512` vs `tg128`, battery °C before/after |
| **No cliff on launch** | none | model load + warmup finish before the user has typed; first message pays nothing extra | warmup at load (`warmUpLocked` / `warmupContext`), cold-vs-warm ttft |
| **Never dies** | n/a | no prompt length, attachment size or context size can abort the process | smoke Part 3 (over-length clamp + chunked prefill), `MemoryFitness` gates |
| **Memory** | n/a | never jetsam/OOM-killed for a model the selector approved | `IPhoneModelSelector` / `AndroidModelSelector` per-app budget; n_ctx from headroom |

## Where we stand (2026-09-05)

Mac M3 Pro, Metal, vendored pin 0eca4d4, **load average ≈ 20 from another workload** — lower bounds. Full rows
in `docs/BENCH_BASELINE.md`.

| Target | Llama 3.2 1B Q4 | Gemma 3 4B Q4 | Verdict |
|---|---|---|---|
| First token, model loaded, warmed | 27 ms | 114–142 ms | ✅ cloud-class |
| First token, first message after install, **before this pass** | 47 ms (page cache was warm) | **3.7 s** | ❌ was the cliff → ✅ warmup at load lands it at the warmed number |
| Streaming | 79 tok/s | 27 tok/s | ✅ |
| Sustained tg512 / tg128 | 1.01 | not run | ✅ (desktop; phone pending) |
| Long-prompt prefill on Android | **process abort** above 512 tokens | same | ❌ → ✅ `decodeChunked` + `clampToContext` (this pass) |
| Phone numbers (S23, SM8550 i8mm) | pending — binaries built, phone was unplugged / 49 °C | | ⏳ run `scripts/bench_inference.sh android` with the phone cool |

## Known gaps still open (engineering, ordered by user impact)

1. **UI per-token cost** — ✅ paced (2026-09-05): `StreamFlushGate` twins coalesce transcript writes to ≤ 30/s
   (first piece immediately, settle always), so the list diff + Markdown re-parse run per frame, not per token.
   Still open: render plain text while streaming and parse Markdown once at settle; verify on device with
   per-token timestamps.
2. **Phone measurement.** The S23 rows above are the ones that decide whether the CPU-variant build actually
   loaded (prefill must be several × decode with i8mm). Blocked on the phone being attached and cool.
3. **Smoothness instrumentation.** Add `os_signpost` / logcat timestamps around prefill and each decode so
   inter-token gaps are a number in a device log, not a feeling.
4. **Context is small on phones** (512–4096 tokens vs 128k in the cloud). Honest today (windowed history);
   the lever is KV-cache quantization already in place plus the mid-conversation context-shift. Not a cliff,
   but the difference a long session feels.

## How to re-measure

```bash
scripts/bench_inference.sh mac                 # this Mac: ceilings + cold/warm first token + shipped-loop gates
scripts/bench_inference.sh android             # attached phone; refuses above 38 °C battery
```

Append new rows to `docs/BENCH_BASELINE.md` and re-grade the table above. A target that regresses is a bug:
journal it (`docs/BUG_JOURNAL.md`) with the number.
