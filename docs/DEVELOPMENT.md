# Development

## Prerequisites

- A recent **Node.js LTS** (18+) and npm.
- macOS, Linux, or Windows. (Native `node-llama-cpp` builds per-platform; on an
  unsupported platform the dashboard/API still run, only local inference is off.)
- Optional: a GGUF model — the setup wizard downloads one for you, or `POST
  /api/models/download`.

## Install

```bash
npm install            # backend deps
cd ui && npm install   # UI deps
cd ..
```

## Run

| Command | What it does |
|---------|--------------|
| `npm run dashboard` | Start the server + UI → `http://localhost:3000` |
| `npm run electron:dev` | Build TS, then launch the full Electron desktop app |
| `npm run agent` | Run the agent loop headless (no UI) |
| `cd ui && npm run dev` | UI only with hot reload → `http://localhost:5173` (needs the backend on `:3000` for data) |

## Build

| Command | Output |
|---------|--------|
| `npm run build:tsc` | Compile `src/` → JS (required after changing `src/` or `electron/`) |
| `cd ui && npm run build` | Build the UI → `public/` (served by Express) |
| `npm run electron:build` | Package the macOS app (`electron-builder`) |
| `npm run electron:build:linux` / `:win` / `:all` | Other targets |

## Quality gates

| Command | Checks |
|---------|--------|
| `npm run check` | typecheck + lint + recommendation test (the full gate) |
| `npm run typecheck` | `tsc --noEmit` for both `src/` and `ui/` |
| `npm run lint` | ESLint (`--max-warnings=0`) for `src/` and `ui/` |
| `npm run test:recommendation` | The model-recommendation/parity test (`vitest`) |

> ESLint runs automatically via a hook. Keep `npm run typecheck` green after every
> change — the project rule is no `any`/`@ts-ignore` without a comment.

## Where data lives

Everything local, under `~/.quenderin/`:

| Path | Contents |
|------|----------|
| `~/.quenderin/models/` | Downloaded GGUF model files |
| `~/.quenderin/config.json` | Saved configuration |
| `~/.quenderin/memory.json`, `corrections.json` | RAG memory (trajectories + embeddings) |

## Environment variables

| Var | Effect |
|-----|--------|
| `PICOVOICE_ACCESS_KEY` | Enables wake-word voice control (optional; voice is off without it) |
| `CI` / `GITHUB_ACTIONS` | Disables browser auto-open (non-interactive) |

## Project layout

```
quenderin/
├── src/                  # TypeScript backend
│   ├── index.ts          # CLI entry (dashboard | agent)
│   ├── server.ts app.ts  # Express + WebSocket boot
│   ├── electron/         # Electron main + preload
│   ├── routes/           # REST routes
│   ├── websocket/        # WebSocket protocol
│   ├── services/         # LLM, agent, session, memory, voice, tools, providers…
│   ├── utils/            # logger, hardware, memory…
│   └── constants.ts      # model catalog, limits
├── ui/                   # React + Vite + Tailwind dashboard
├── public/               # built UI (served by Express)
├── tests/                # vitest tests
├── apple/                # native iOS/Android rebuild (Swift package + app)
├── website/              # marketing site
└── docs/                 # ← you are here
```

## Conventions recap

- Changes to `src/` or `electron/` require a rebuild (`npm run build:tsc`); UI
  changes hot-reload under Vite.
- IPC channels (Electron main ↔ renderer) are typed in both directions; use
  `contextBridge`, never `nodeIntegration`.
- New WebSocket message types → update the TypeScript interfaces both ways and
  [API.md](API.md).
- See [../CONTRIBUTING.md](../CONTRIBUTING.md) for the contribution workflow.
