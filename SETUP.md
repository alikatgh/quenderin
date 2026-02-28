# Setup Guide

Detailed setup for local development, production builds, and stable operation.

---

## System requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| Node.js | 20.x | 22.x or 25.x |
| npm | 9.x | 10.x |
| RAM | 4 GB (Llama 3.2 3B) | 10 GB (Llama 3 8B) |
| Storage | 4 GB (model) + 500 MB (code) | 20 GB (all models) |
| OS | macOS 12+, Ubuntu 22+, Windows 10+ | macOS (Apple Silicon) |

**Optional extras:**
- An Android device + ADB (for device automation features)
- `PICOVOICE_ACCESS_KEY` (for wake-word / voice control features)
- Xcode (for iOS development on the `off-grid-mobile` sub-project)

> `node-llama-cpp` ships prebuilt native binaries — no Xcode, Python, or CMake required for the dashboard.

---

## Install

```bash
# Clone the repository
git clone https://github.com/alikatgh/quenderin.git
cd quenderin

# Install backend dependencies
npm install

# Install frontend dependencies
cd ui
npm install
cd ..
```

---

## Build the UI

The dashboard uses a Vite-built React frontend. Build it once before first run, and rebuild whenever you change UI source files:

```bash
cd ui
npm run build
cd ..
```

Build output goes to `public/` in the project root, which is served by the Express backend at `/`.

To develop the UI with hot-module replacement (HMR):

```bash
cd ui
npm run dev
```

This starts Vite's dev server on `http://localhost:5173`. The backend must also be running separately for API/WebSocket calls to work.

---

## Configuration file

Quenderin reads an optional `quenderin.json` file from the project root. Create one to override defaults:

```json
{
  "maxTokens": 2048,
  "temperature": 0.7,
  "threads": 4,
  "outputDir": "src/gen"
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `maxTokens` | number | 2048 | Maximum tokens per generation |
| `temperature` | number | 0.1 | Default generation temperature (presets override this) |
| `threads` | number | 4 | CPU thread count for inference |
| `outputDir` | string | `"src/gen"` | Directory for agent-generated output files |
| `provider` | string | `"gguf"` | LLM provider: `"gguf"` (local), `"ollama"`, `"openai"`, or `"auto"` |
| `modelPath` | string | — | Explicit GGUF model path (overrides auto-selection) |
| `modelName` | string | — | Model name (for Ollama or OpenAI provider) |
| `apiKey` | string | — | API key (OpenAI provider only) |
| `baseURL` | string | — | Base URL override (Ollama or custom OpenAI-compatible endpoint) |

If `quenderin.json` is absent, all values use defaults.

---

## Run modes

### Dashboard (primary)

```bash
npm run dashboard
```

Starts Express + WebSocket + serves the React UI at `http://localhost:3000`.

### Agent backend only

```bash
npm run agent
```

Runs the autonomous agent loop without the browser UI. Use this for headless or scripted operation.

### Electron desktop app (development)

```bash
npm run electron:dev
```

Wraps the dashboard in a native window. The Electron main process is in `electron/main.ts`.

### Electron desktop app (production build)

```bash
npm run electron:build
```

Produces a signed macOS `.dmg` in the `release/` directory using `electron-builder`. Build config is in `electron-builder.yaml`.

---

## Model setup

### Where models are stored

All GGUF model files are stored at:

```
~/.quenderin/models/
```

This directory is created automatically on first run. You can also set `modelPath` in `quenderin.json` to point to a model file at any path.

### Downloading models

Use the **Models** tab in the dashboard, or trigger a download via the WebSocket API:

```json
{ "type": "download_model", "modelId": "llama-3.2-3b" }
```

Download progress is streamed back as `download_progress` WebSocket events. If interrupted, the download resumes automatically using HTTP range requests — partial files are preserved.

### RAM-aware auto-selection

At startup, `LlmService` iterates the model catalog (8B → 3B → 1B) and picks the first model that:
1. Exists on disk
2. Fits within safe memory limits (when memory safety is enabled)

You can disable memory safety in Settings if you want to force-load a larger model.

### Model lifecycle

| Event | What happens |
|-------|-------------|
| First chat message | Model loaded from disk into memory |
| Concurrent requests during load | Deduplicated — only one load occurs |
| 30 min idle | Model automatically unloaded to free RAM |
| `switch_model` WebSocket message | Previous model unloaded; new model loads on next request |
| Active generation | Idle timer paused; model never unloaded mid-generation |

---

## Context size and memory

Context size controls how many tokens the model keeps in its working memory for a conversation.

| Context | RAM overhead | Suitable for |
|---------|-------------|--------------|
| 512 | ~200 MB | Very constrained systems |
| 1024 | ~400 MB | Short conversations |
| 2048 | ~800 MB | Standard (default) |
| 4096 | ~1.5 GB | Long documents and detailed coding sessions |
| 8192 | ~3 GB | Maximum — requires ≥12 GB free RAM with 8B model |

Only allowlisted values are accepted. Settings outside this range are rejected by the backend.

---

## Tool calling setup

Tool calling requires no extra configuration. Built-in tools are always available when the LLM is loaded. The LLM receives a tool description block in its system prompt and emits `<tool_call>` XML tags when it wants to use a tool.

**Tool loop safety limits:**
- Maximum 3 tool calls per response
- Maximum 3 loop iterations
- Tools run synchronously before the final response is returned
- All execution is sandboxed — no shell access, no `eval`

---

## Security defaults

| Protection | Behavior |
|------------|---------|
| CORS | Local-origin restriction on all API endpoints |
| Docs route | `path.basename()` + `.md` extension required — directory traversal blocked |
| WebSocket origin | Non-local origins rejected at connection time |
| Settings validation | All incoming values validated against allowlists |
| Privacy lock | Optional PIN-based lockout with configurable idle timeout |
| Error responses | Internal stack traces not forwarded to clients |

---

## Verify build health

After any changes, verify both TypeScript projects compile cleanly:

```bash
# Check backend
npx tsc --noEmit

# Check UI
cd ui && npx tsc --noEmit && cd ..
```

Both should produce no output (exit code 0). If errors appear, fix those files before committing.
Do not edit generated artifacts such as `ui/tsconfig.tsbuildinfo`.

To also verify the UI bundles correctly:

```bash
cd ui && npm run build
```

A successful build ends with: `✓ built in X.XXs`
