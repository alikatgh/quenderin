# Backend

The TypeScript backend in `src/`. It runs as a plain Node server
(`npm run dashboard`) or wrapped in Electron (`npm run electron:dev`).

## Entry points

| File | Role |
|------|------|
| `src/index.ts` | CLI (`commander`): `dashboard` (server + UI) and `agent` (headless agent loop) |
| `src/server.ts` | Boots Express + WebSocket, dependency-injects services, temp-file cleanup, graceful shutdown, process-level safety nets |
| `src/app.ts` | The Express app: all `/api/*` routes, static UI from `public/` |
| `src/electron/main.ts` | Electron main process — owns the dashboard server + the window |
| `src/electron/preload.ts` | `contextBridge` API (no `nodeIntegration`) |
| `src/constants.ts` | Model catalog, RAM tiers, limits/thresholds |

## Services (`src/services/`)

### LLM (`llm.service.ts`)
The core. Loads/unloads GGUF models via `node-llama-cpp`, runs inference with
**AbortController-based timeouts** (real cancellation), tracks the GPU backend and
flash-attention state, and manages the **model catalog** (`MODEL_CATALOG`),
downloads (resumable, with progress events), and **memory-fitness** checks
(`checkMemoryForModel`) so it refuses to load a model that won't fit. Lifecycle:
idle models are released after a timeout to reclaim RAM.

### Agent (`agent.service.ts` + `agent/`)
The OS agent loop — `runAgentLoop(goal, emitter, history, maxSteps)`. Composed of:
- `agent/promptBuilder.ts` — assembles perception + history into the planner prompt.
- `agent/actionExecutor.ts` — maps the LLM's symbolic action (`{action,id}`) to
  real input, with the **safety blocklist** gate.
- `agent/uiVerifier.ts` — confirms the UI changed as intended (state verification).

### Perception
- `providers/desktop.provider.ts` / `providers/android.provider.ts` — capture the
  screen and perform input (desktop automation / Android ADB).
- `uiParser.service.ts` — turns a raw screen into a compact, LLM-readable UI tree.
- `ocr.service.ts` — extracts text from screenshots to enrich perception.

### Conversation & memory
- `session.service.ts` — persists conversations, history, export (caps via
  `MAX_SESSIONS` / `MAX_MESSAGES_PER_SESSION`).
- `memory.service.ts` — a RAG store: past **trajectories** (goal + actions) and
  **corrections** (384-dim Xenova embeddings) in `~/.quenderin/`, retrieved by
  similarity to inform future runs.
- `presets.ts` — assistant personas (General/Code/Writer/Tutor/Summary).
- `intentClassifier.ts` — routes input between chat and an agent objective.

### Tool-use (`tools/`)
The chat assistant's tool loop:
- `tools/toolLoop.ts` — plan → call tool → observe → repeat.
- `tools/registry.ts` — the tool catalog (see below).
- `tools/handlers.ts` — executes a parsed tool call.
- `tools/calculator.ts` — a safe expression evaluator.

**Built-in tools:** `calculator`, `expression`, `datetime`, `system_info`,
`read_file`, `note_save`, `note_list`.

### Voice, daemons, metrics, readiness
- `voice.service.ts` — Picovoice wake-word + speech; pipes spoken commands into
  the agent. Gated on `PICOVOICE_ACCESS_KEY` (optional).
- `backgroundDaemon.service.ts` — passive observation; triggers the LLM only when
  the screen changes beyond `VISUAL_DIFF_THRESHOLD` (adaptive backoff when idle).
- `metrics.service.ts` — tok/s, TTFT, RAM, loaded-model telemetry.
- `readiness.service.ts` — drives `/ready` and `/health`.

## Utilities (`src/utils/`)

| File | Purpose |
|------|---------|
| `logger.ts` | Structured logging (levels: debug/info/warn/error/critical) — used everywhere instead of `console.*` |
| `hardware.ts` | Hardware profile (RAM/chip), adaptive timeout multipliers, memory budgets |
| `memory.ts` | Available-memory probing |
| `stripControlTokens.ts` | Cleans model output of control tokens |

## Conventions

- **No `any`** in shared types without a comment; **no `@ts-ignore`** without a
  comment. Run `npm run typecheck` after changes.
- **Never hardcode model paths** — use the catalog + discovery logic.
- **Never remove safety-blocklist entries.**
- **Errors propagate to the UI** (via WebSocket `error` events) — never silently
  swallowed.
- New WebSocket message types must be added to the TypeScript interfaces in both
  directions. See [API.md](API.md).
