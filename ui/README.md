# Quenderin Dashboard UI

The React front-end for the Quenderin dashboard — chat, governed tasks, the device
agent, metrics, and settings (including the AI Model Manager). Served in production
by the local Node backend; run standalone against it during development.

## Stack

- **React 18 + TypeScript**, built with **Vite**
- **Tailwind CSS** for styling
- State over a single **WebSocket** (`src/hooks/useAgentSocket.ts`) plus REST
  helpers (`src/lib/api.ts` — every state-changing call goes through `apiFetch`,
  which attaches the per-launch `X-Auth-Token`)

## Development

Start the backend first (from the repo root):

```bash
npx tsx src/index.ts dashboard --no-open
# prints: Open this URL to connect: http://localhost:3000/?token=<per-launch token>
```

Then the UI dev server:

```bash
cd ui && npm run dev
```

Open `http://localhost:5173/?token=<token from the backend log>`. Vite proxies
`/api` and the WebSocket to `localhost:3000` (see `vite.config.ts`), and the
renderer reads the token from `?token=` once, then strips it from the URL.

## Build

```bash
npm run build      # from ui/, or `npm run build:ui` from the repo root
```

Output lands in `ui/dist` and is what Electron / the packaged dashboard serves.

## Conventions

- New WebSocket message types must be added to the interfaces on **both** sides
  (client `src/hooks/useAgentSocket.ts` server-message union, server `src/types/`)
  and to the tables in `docs/API.md`.
- Model management (catalog, download, delete, switch) is **REST-only** — the
  WS `switch_model` twin was removed after it drifted unused (r9 H1).
- All inference is 100% local (`node-llama-cpp`); there is no external-provider
  configuration. (An earlier version of this README described a long-dead Ollama
  drag-and-drop setup page on port 3777 — that UI no longer exists; r7 C1.)
