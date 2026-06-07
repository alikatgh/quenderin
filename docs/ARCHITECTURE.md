# Architecture

## The thesis

**Offline, on-device AI.** The model runs on the user's machine — not in a data
center. No API keys, no accounts, no telemetry, no per-token cost. Everything in
this codebase exists to make that practical, reliable, and usable.

## Two products, one vision

| | **Desktop** (this repo's `src/` + `ui/`) | **Mobile** (`apple/`) |
|---|---|---|
| Status | Shipping prototype | In active development |
| Stack | Electron + TypeScript + React/Vite | Native Swift (iOS), Kotlin (Android) |
| Engine | `node-llama-cpp` (Node binding to llama.cpp) | `LlamaEngine` (Swift → llama.cpp C API) |
| Role | Proves the concept; the testbed | The real destination — AI in your pocket |

This document covers the **desktop** system. For the native stack and the
all-important *engine-vs-model* distinction, see
[`../apple/ARCHITECTURE.md`](../apple/ARCHITECTURE.md).

## High-level shape (desktop)

```
┌─────────────────────────── Electron app ───────────────────────────┐
│                                                                     │
│  electron/main.ts ──► spawns/owns the dashboard server              │
│                                                                     │
│  ┌───────────────┐     WebSocket      ┌──────────────────────────┐  │
│  │  React UI      │◄──────────────────►│  Express + ws server      │  │
│  │  (ui/, Vite)   │     REST (/api/*)  │  (src/server.ts,          │  │
│  │                │◄──────────────────►│   src/websocket/,         │  │
│  └───────────────┘                    │   src/routes/)            │  │
│         ▲                              └──────────┬───────────────┘  │
│         │ contextBridge (preload)                 │                   │
│         ▼                                         ▼                   │
│  Renderer (no nodeIntegration)        Services (src/services/)        │
│                                       LLM · Agent · Session · Memory  │
│                                       Voice · OCR · Daemons · Tools   │
│                                                   │                   │
│                                                   ▼                   │
│                                    Device provider (desktop/android)  │
│                                    + local GGUF model (node-llama-cpp)│
└─────────────────────────────────────────────────────────────────────┘
```

- **Entry points:** `src/index.ts` is a CLI (`commander`) with two commands —
  `dashboard` (start the server + UI) and `agent` (run the agent loop headless).
  `src/electron/main.ts` is the Electron main process that wraps the dashboard in
  a desktop window.
- **Server:** `src/server.ts` boots an Express app (`src/app.ts`) + a WebSocket
  manager (`src/websocket/index.ts`), wires up all services via dependency
  injection, serves the built UI from `public/`, and handles graceful shutdown.
- **UI:** `ui/` is a React + Vite + Tailwind app. In dev it runs on Vite
  (`localhost:5173`); in production it's built to `public/` and served by Express.
- **Security:** Electron uses `contextBridge` via `src/electron/preload.ts` — no
  `nodeIntegration`. The renderer talks to the backend only over WebSocket/REST.

## The two loops

Quenderin has **two distinct agent loops** — don't confuse them:

### 1. The OS agent loop (`src/services/agent.service.ts`)
The vision's *perception → planning → execution* cycle, for driving a real
device's UI. Each turn emits a WebSocket event the UI renders live:

```
observe ──► decide ──► action ──► (verify) ──► observe ...
   │           │          │            │
perception   LLM as     deterministic  uiVerifier confirms the
(screenshot/ symbolic    executor       UI changed as intended
 UI tree via planner    (actionExecutor)
 provider +  → JSON
 uiParser)   {action,id}
```

- **Perception:** the device provider (`providers/desktop.provider.ts` or
  `android.provider.ts`) captures the screen; `uiParser.service.ts` turns it into
  a compact, LLM-readable structure (OCR via `ocr.service.ts` fills gaps).
- **Planning:** `agent/promptBuilder.ts` assembles context; the LLM returns a
  **symbolic** action (e.g. `{"action":"click","id":5}`), never raw coordinates.
- **Execution:** `agent/actionExecutor.ts` maps the symbolic id to real bounds and
  performs the input.
- **Verification:** `agent/uiVerifier.ts` checks the result, so divergence is
  caught instead of silently compounding.
- **Safety:** a hardcoded blocklist (Pay/Delete/Password/…) prevents the agent
  from autonomously touching destructive or sensitive elements.

### 2. The chat tool loop (`src/services/tools/toolLoop.ts`)
A modern *tool-use* loop for the chat assistant: the model plans a tool call, a
handler runs it, the observation feeds back, repeat. Tools live in
`src/services/tools/registry.ts` (calculator, datetime, system_info, read_file,
note_save, note_list, …). This is the on-device-friendly form of "agency" — it
acts through tools, not by driving the OS.

> The native mobile `AgentLoop` (`apple/`) is a clean re-implementation of loop #2.

## Service map

| Service | Responsibility |
|---------|----------------|
| `llm.service.ts` | Loads/unloads GGUF models, runs inference (abort-based timeouts, GPU diagnostics), model catalog + downloads, memory-fitness checks |
| `agent.service.ts` | The OS agent loop (observe→decide→action→verify) |
| `session.service.ts` | Conversation persistence, history, export |
| `memory.service.ts` | RAG over past trajectories + corrections (Xenova embeddings) |
| `metrics.service.ts` | tok/s, TTFT, RAM, model-loaded telemetry |
| `voice.service.ts` | Wake-word + speech (Picovoice), pipes commands into the agent |
| `ocr.service.ts` | Text extraction from screenshots (perception) |
| `uiParser.service.ts` | Screen → compact LLM-readable UI tree |
| `backgroundDaemon.service.ts` | Passive observation; triggers on visual change |
| `daemon.service.ts` | Long-running task/daemon management |
| `readiness.service.ts` | Server readiness state (`/ready`, `/health`) |
| `intentClassifier.ts` | Routes input (chat vs. agent objective) |
| `presets.ts` | Assistant personas (General/Code/Writer/Tutor/Summary) |
| `tools/*` | The chat tool-use loop + registry + handlers |
| `providers/*` | Device abstraction (desktop screen/input, Android ADB) |

## Data flow (a chat message)

1. UI sends a `chat` message over WebSocket (`useAgentSocket.ts`).
2. `websocket/index.ts` validates it (length caps, attachment limits), picks the
   active preset, and calls into the LLM / tool loop.
3. Tokens stream back as `chat_stream` events; a final `chat_response` closes it.
4. `metrics.service` records tok/s; `session.service` persists the exchange.

## Data flow (an agent objective)

1. UI sends a `start` message with a goal.
2. `agent.service.runAgentLoop(goal, emitter, history, maxSteps)` begins.
3. Each turn emits `observe` → `decide` → `action`; the Inspector panel renders
   them. `action_required` pauses for human confirmation when needed.
4. `done` (or `error`) ends the run.

See **[API.md](API.md)** for the full message catalog and **[BACKEND.md](BACKEND.md)**
for service internals.
