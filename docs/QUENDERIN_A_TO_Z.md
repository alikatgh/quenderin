# Quenderin — A to Z

> The single front door to the whole project. Read this top-to-bottom once and you'll understand
> *what* Quenderin is, *how* every part works, *where* each detail lives, and *what's actually
> done vs. left*. It synthesizes the ~25 deep docs (linked inline) so you don't have to assemble
> them yourself. Honest throughout — it says "mock", "estimated", and "not done" where that's true.
>
> Companion: [`INFERENCE_101.md`](INFERENCE_101.md) goes deep on *how a model actually generates text*.
> This doc is the breadth; that one is the depth on the engine.

---

## A. What Quenderin is (in one breath)

**A private, offline, on-device AI chat assistant for iOS and Android.** The model runs *on the phone*
via llama.cpp — no internet, no API keys, no accounts, no telemetry, no per-token cost. (Full identity
decision: [`PRODUCT.md`](PRODUCT.md).)

**The wedge — where cloud AI structurally cannot follow:**
> "AI that works with no signal and never leaves your phone."

It does **not** try to beat GPT-5 on raw answer quality (a 1–4B on-device model loses that, and should
not compete there). It wins by *existing* where cloud can't: on a plane, off-grid, or for anything too
private to send to a server. Three user wedges: **no-connectivity**, **privacy-required**, and **free /
no-account**.

## B. Two products, deliberately split (this is load-bearing)

| | **Quenderin Mobile** — the product | **Quenderin Desktop** — dev prototype |
|---|---|---|
| What | Private offline chat + a *safe pure-compute* tool agent (math, unit/date) | A research tool that can *drive* an Android device (read screen, click, type) |
| Stack | Swift (iOS), Kotlin (Android), llama.cpp | Electron + TypeScript + React |
| Ships to | App Store / Play Store | **nowhere** — dev-only |
| The "agent" | bounded to side-effect-free tools | full device automation |

**Why the split matters:** an autonomous device-controller on mobile = an Accessibility Service that
clicks for the user = a store-review red flag *and* a security liability (a prompt-injected model
driving your phone). So the device-agent **stays desktop-only, forever**. The feature-triage test:
*does it serve "private, offline, on-device chat"?* If not, it's desktop or it's out.

**In (mobile):** offline chat · device-aware model selection + download + integrity · history +
export · model storage management · the safe tool agent · settings + model switching · on-device
content-safety · the hardware-adaptation layer.
**Out (mobile):** device automation · any cloud call · accounts · telemetry · anything that breaks
"nothing you type leaves your phone."

---

## C. The whole system at a glance

```
                         ┌───────────────────────────────────────┐
                         │   THE PRODUCT — native mobile apps      │
   ┌──────────────┐      │                                         │
   │  Marketing    │     │   iOS (apple/QuenderinApp, SwiftUI)     │
   │  website/     │     │   Android (android/app, Compose)        │
   │  quenderin.org│     │            │            │                │
   └──────────────┘      │            ▼            ▼                │
                         │   ┌─────────────────────────────────┐   │
                         │   │  The shared "brain" (logic)      │   │
                         │   │  model-pick · thread/thermal ·   │   │
                         │   │  KV-cache · context-sizing ·     │   │
                         │   │  download/integrity · agent loop │   │
                         │   │   iOS: QuenderinKit  ·  Android: │   │
                         │   │   quenderin-core                 │   │
                         │   └────────────────┬────────────────┘   │
                         │                    ▼                     │
                         │        llama.cpp (the engine)            │
                         │   iOS: Swift C-API  · Android: JNI       │
                         └───────────────────────────────────────┘

   ┌────────────────────────────────────────────────────────────┐
   │   DEV PROTOTYPE — desktop (NOT shipped)                       │
   │   Electron (electron/main.ts) → Express+ws server (src/)     │
   │   → React UI (ui/) → node-llama-cpp → local GGUF             │
   └────────────────────────────────────────────────────────────┘
```

**One engine, three clients.** Desktop (TS/`node-llama-cpp`), iOS (Swift/C-API), Android (Kotlin/JNI)
all wrap the *same* llama.cpp and implement the *same* logic — only the language + device tuning
differ. A Python parity gate (`scripts/check_catalog_parity.py`, `check_agent_parity.py`) keeps the
three in lockstep. (Desktop design: [`ARCHITECTURE.md`](ARCHITECTURE.md); native + the engine-vs-model
distinction: [`../apple/ARCHITECTURE.md`](../apple/ARCHITECTURE.md).)

**The one distinction you must never conflate (`apple/ARCHITECTURE.md`):** the **engine** (llama.cpp —
runs *any* model) vs. the **model** (a GGUF file — the weights). Quenderin ships the engine; the user
downloads a model into it. Both apps default to a **mock engine** and switch to the real `LlamaEngine`
only when llama.cpp is linked — so the default test build runs without a model.

---

## D. How it actually works (the engine) — the 60-second version

Full version: [`INFERENCE_101.md`](INFERENCE_101.md). The essentials:

- **Generating one token reads ~all the model's weights from RAM once.** So
  `tokens/sec ≈ memory_bandwidth ÷ model_size`. This is why phones are slow at it — they're
  bandwidth-bound, not compute-bound.
- **Two phases:** *prefill* (reads your prompt, compute-bound, GPU helps) and *decode* (generates the
  reply one token at a time, memory-bound, GPU barely helps).
- **The loop** (`apple/QuenderinKit/Sources/QuenderinKit/LlamaEngine.swift:196`): tokenize → sample a
  token → `llama_decode` (the expensive forward pass) → feed it back → repeat until the
  end-of-generation token.
- **The ceiling:** sustained decode is capped by bandwidth, and phones *throttle* under heat (10–44%
  per `apple/REALITY.md`). Quenderin's in-flight thermal governor sheds threads as the chip heats to
  stay sustainable. Whether this ceiling is fundamental is the open question emailed to Georgi Gerganov.

---

## E. Models — catalog, quantization, download, selection

- **One catalog, 11 models, three platforms.** Canonical source `shared/model-catalog.json`, generated
  from desktop `src/constants.ts` by `scripts/export_catalog.py`, mirrored to iOS `ModelCatalog.swift`
  + Android `ModelCatalog.kt`. CI's `check_catalog_parity.py` fails the build if they drift or if any
  model lacks a pinned `sha256`.
- **Quantization** (`Q4_K_M` default) = ~4.5 bits/weight → a 4B model is ~2.4 GB and ~3× faster to
  decode than full precision, at a small quality cost. The speed/size↔quality dial.
- **Download + integrity** (`src/services/modelIntegrity.ts`, `apple/.../ModelIntegrity.swift`,
  Android `ModelDownloadEngine`): HTTPS-only, streamed with resume, then verified by GGUF magic +
  sha256 before the file is ever loaded (a poisoned/MITM'd file is rejected).
- **Device-aware selection** ([`apple/MODEL_SELECTION.md`](../apple/MODEL_SELECTION.md),
  `IPhoneModelSelector`): *not* a naive RAM heuristic — it gates on the **per-app memory budget**
  (iOS jetsam / Android native heap), **chip throughput**, and **disk**, then defaults to the largest
  *comfortable* model and surfaces an honest heat/battery expectation. iPhone SE/12/13 → 1B;
  13 Pro/15/16 Pro → Qwen3 4B; Android 12–16 GB flagships → Mistral 7B.

## F. The desktop app (`src/` + `ui/`, dev prototype)

Electron shell (`electron/main.ts`) → Express + WebSocket server (`src/server.ts`, `src/app.ts`,
`src/websocket/`) → React/Vite UI (`ui/`), talking only over WS/REST via a `contextBridge` preload (no
`nodeIntegration`). Two **distinct** loops (don't confuse them):

1. **OS agent loop** (`src/services/agent.service.ts`) — observe → decide → action → verify, for
   driving a device's UI. Desktop-only.
2. **Chat tool loop** (`src/services/tools/toolLoop.ts`) — the model calls side-effect-free tools
   (calculator, unit_convert, datetime, read_file, note_save…). This is the mobile-safe form of agency;
   the native `AgentLoop` is a clean re-implementation of *this* loop.

Service map + data flows: [`BACKEND.md`](BACKEND.md); UI: [`FRONTEND.md`](FRONTEND.md); the WS/REST
message catalog: [`API.md`](API.md).

## G. The iOS app (`apple/`)

- **`QuenderinKit`** — the shared "brain": pure Foundation, *zero UI deps*, so it **compiles and
  unit-tests standalone** (`cd apple/QuenderinKit && swift build && swift test` → ~199 tests). Holds
  `LlamaEngine` (Swift → llama.cpp C-API), model selection, `ThreadPlanner`, `ThermalMonitor`,
  `KVCachePolicy`/`KVCacheReuse`, `ContextWindow`, `ModelCatalog`, the `AgentLoop`.
- **`QuenderinApp`** — the thin SwiftUI app shell (onboarding, chat, settings, history).
- **Real inference** activates when the `llama.xcframework` is present (`Package.swift` auto-detects it
  via `canImport(llama)`), else the mock. Build/run: [`BUILD_MOBILE.md`](BUILD_MOBILE.md).

## H. The Android app (`android/`)

- **`quenderin-core`** — the Kotlin twin of QuenderinKit (download/inference/integrity/conversation
  brain), pure-Kotlin so `kotlinc` + `CoreVerify.kt` runs it headless in CI.
- **`app`** — the Jetpack Compose UI + a `WorkManager` background downloader; real inference via JNI
  (`android/jni/llama_jni.cpp`) when `jni/llama.cpp` is present (auto-detected in `build.gradle.kts`),
  else mock. Network-security-config enforces HTTPS; `conversations/` excluded from cloud backup.

## I. The shared "brain" — cross-platform parity

The interesting engineering lives here, mirrored across iOS (Swift) + Android (Kotlin), kept in sync by
`check_agent_parity.py`. **Deep dive with the exact code + numbers: [`MOBILE_PERFORMANCE_101.md`](MOBILE_PERFORMANCE_101.md).**
- **`ThreadPlanner`** — use performance cores only (E-cores are slower + hotter for matmul decode).
- **`ThermalMonitor` + governor** — re-tune thread count *during* a long decode as the SoC heats
  (`llama_set_n_threads` every 32 tokens).
- **`KVCachePolicy` / `KVCacheReuse`** — q8_0 cache (~2× context) + decode only the new suffix each turn
  (flat time-to-first-token).
- **`ContextWindow`** — size `n_ctx` from the real app-memory budget − the model's footprint (jetsam-safe).
- **`GpuOffloadPlanner`** (Android) — conservative per-SoC Vulkan offload (decode is bandwidth-bound, so
  GPU mainly helps prefill).

## J. Privacy & security

- **The guarantee:** nothing the user types leaves the phone. No cloud, no accounts, no telemetry.
  Transcripts live in `filesDir/conversations` (Android) and are excluded from cloud backup /
  device-transfer.
- **Hardened surfaces** (from the 2026-06 security audit, `docs/audits/`): per-launch token auth on the
  desktop WS/HTTP server; `read_file` tool has a sensitive-path denylist; model integrity is sha256 +
  GGUF-magic with the catalog forced to pin hashes; Electron runs sandboxed + asar-packed; Android
  enforces HTTPS + excludes transcripts from backup. **All 10 HIGH audit findings are resolved or
  mitigated** (`docs/audits/2026-06-23-code-review-security-audit.md`); the MEDIUM/LOW tier was
  re-swept (`2026-06-30-medlow-resweep.md`).

## K. The website (`website/`, quenderin.org)

Static HTML/CSS/JS marketing site — self-hosted fonts, **nothing loads from a third party** (enforced by
a CSP). Client-side i18n in **12 languages** (en, zh, hi, es, fr, ar (RTL), bn, pt, ru, id, ja, ko),
~234 keys, swapped into `[data-i18n]` nodes. A service worker makes it work offline. Deploys via GitHub
Pages (**currently failing CI because Pages isn't enabled in repo settings** — a one-click toggle).

## L. Build, test, run, ship

| Platform | Build / run | Test |
|---|---|---|
| Desktop | `npm run electron:dev` / `npm run build` | `npm test` (235 tests) · `npm run lint` · `typecheck` |
| iOS | build `llama.xcframework` → flip `Mock*`→real → `xcodegen` → run | `cd apple/QuenderinKit && swift test` (199) |
| Android | add `jni/llama.cpp` → `./gradlew :app:assembleDebug` | kotlinc `CoreVerify` (177 checks) |
| Catalog | `npm run gen:catalog` | `check:catalog-parity`, `check:agent-parity` |

**CI** (`.github/workflows/ci.yml`) runs 6 jobs — desktop (Node 20+22), coverage, iOS tests, Android
core, Android APK, catalog parity — **all green**. Ship process: [`SHIP_READINESS.md`](SHIP_READINESS.md),
[`RELEASE.md`](RELEASE.md), [`STORE_SUBMISSION.md`](STORE_SUBMISSION.md), [`STORE_LISTING.md`](STORE_LISTING.md),
on-device runbook [`DEVICE_VERIFICATION.md`](DEVICE_VERIFICATION.md).

## M. The honest state (what's done vs. left)

**Done + verified (software):** all CI gates green; full feature parity (M1–M4: onboarding, chat,
offline-readiness, the safe agent loop) on both mobile platforms; real llama.cpp inference *proven*
on Mac/sim (~157–177 tok/s); security HIGHs resolved; 12-language site.

**The honest asterisks:**
1. Both apps **default to a mock engine**; real inference is exercised by model-gated tests, not the
   default suite.
2. **Never run on a physical phone** — every tok/s is a Mac/sim ceiling or a labeled estimate.
3. **Not submitted** to either store.

**What's left = almost entirely *you* things** (`SHIP_READINESS.md` "needs-you" list): run on a real
device + measure real tok/s; Apple/Google accounts + signing + screenshots; fill legal placeholders;
enable GitHub Pages. The software is done; the remaining path is hardware + accounts + settings.

## N. The hard constraint (worth internalizing)

Sustained on-device decode is bandwidth- and thermal-bound (`apple/REALITY.md`). GPU/NPU help prefill,
not decode ([`NPU_NEURAL_ENGINE.md`](NPU_NEURAL_ENGINE.md) explains why we don't target the NPU yet).
The real levers are: a smaller/more-quantized model, KV-cache quant, and **speculative decoding** (the
one trick that beats the single-stream bandwidth wall — the next thing to explore). See
[`INFERENCE_101.md`](INFERENCE_101.md) §6.

---

## O. Glossary (the words that unlock the rest)

- **GGUF** — the model file format (weights + metadata). The first 4 bytes are literally `GGUF`.
- **Quantization (Q4_K_M, q8_0…)** — bits-per-weight. Fewer bits = smaller + faster, slightly lower quality.
- **Token** — a chunk of text (~¾ of a word) the model reads/writes one at a time.
- **Prefill vs. decode** — reading the prompt (parallel, compute-bound) vs. generating the reply
  (sequential, memory-bound).
- **KV cache** — stored intermediate results so the model doesn't recompute past tokens; grows with
  context, lives in RAM.
- **`n_ctx`** — context window size (how many tokens fit); bigger = more KV-cache RAM.
- **`n_threads` / P-cores** — how many performance CPU cores run the matmuls.
- **tok/s** — tokens per second (decode speed). **TTFT** — time to first token (prefill latency).
- **Jetsam** — iOS killing an app that uses too much memory; why model loading is mmap'd and not mlock'd.
- **Thermal throttling** — the SoC slowing its clocks/bandwidth under sustained heat.
- **Mock vs. real engine** — the placeholder used in tests vs. actual llama.cpp inference.

## P. The complete doc map (where every detail lives)

| Topic | Doc |
|---|---|
| **This map / front door** | `docs/QUENDERIN_A_TO_Z.md` (you are here) |
| Product identity, the wedge, in/out | `docs/PRODUCT.md` |
| Desktop architecture, the two loops, services | `docs/ARCHITECTURE.md` |
| Native architecture, engine-vs-model | `apple/ARCHITECTURE.md` |
| How inference works (deep) | `docs/INFERENCE_101.md` |
| Mobile performance & hardware adaptation (deep) | `docs/MOBILE_PERFORMANCE_101.md` |
| llama.cpp C++ engine internals (deep) | `docs/LLAMA_CPP_101.md` |
| Backend services + utils | `docs/BACKEND.md` |
| Frontend (React UI) | `docs/FRONTEND.md` |
| WS/REST API catalog | `docs/API.md` |
| Model picking (iPhone) | `apple/MODEL_SELECTION.md` |
| Real-world speed/heat numbers | `apple/REALITY.md` |
| NPU / Neural Engine landscape | `docs/NPU_NEURAL_ENGINE.md` |
| Build & run the native apps | `docs/BUILD_MOBILE.md` |
| Ship readiness (done vs. needs-you) | `docs/SHIP_READINESS.md` |
| Release & signing | `docs/RELEASE.md` |
| Store submission + listing copy | `docs/STORE_SUBMISSION.md`, `docs/STORE_LISTING.md` |
| On-device verification runbook | `docs/DEVICE_VERIFICATION.md` |
| Security/correctness audits | `docs/audits/*.md` |
| Bug history + patterns | `docs/BUG_JOURNAL.md` |
| Quickstart / setup / run / troubleshoot | `README.md`, `QUICKSTART.md`, `SETUP.md`, `RUN_GUIDE.md`, `TROUBLESHOOTING.md` |
| Contributing | `CONTRIBUTING.md` |

## Q. Get oriented in 15 minutes (the fast path)

1. Read **A–C** above (what it is, the split, the system map) — 3 min.
2. Read **`INFERENCE_101.md` §0** (the one equation) — 2 min. This is the single most clarifying idea.
3. Open **`LlamaEngine.swift:196`** and read the generation loop with §F/§D as your map — 5 min.
4. Run **`apple/verify-llama-link.sh`** and watch real tokens stream — 5 min.

After that you can hold the whole project in your head: a private offline chat app, one engine + three
clients, bottlenecked by memory bandwidth and heat, software-complete and waiting on real hardware.
