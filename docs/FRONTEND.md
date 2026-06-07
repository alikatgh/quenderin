# Frontend

The dashboard UI in `ui/` — **React + Vite + Tailwind + TypeScript**. In
development it runs on Vite (`localhost:5173`); in production it's built to
`public/` and served by the Express backend.

## Entry & shell

- `ui/src/main.tsx` — mounts React.
- `ui/src/App.tsx` — the shell: a `currentView` state switches the main pane, and
  a first-run **WelcomeWizard** (gated on `localStorage['quenderin_setup_complete']`)
  walks new users through setup.

### Views (`currentView`)

| Value | Component | What it is |
|-------|-----------|-----------|
| `general_chat` | `GeneralChatArea` | The default assistant chat (personas, prompt presets) |
| `chat` | `ChatArea` | The "Device Agent" view — the OS agent loop |
| `metrics` | `Metrics` | Performance telemetry (tok/s, RAM, model) |
| `settings` | `SettingsArea` | Model manager, context-window ("RAM Armor"), Privacy Lock |
| `docs` | `Docs` | In-app documentation viewer (reached via "Help") |

The `Inspector` panel overlays the agent view to show live `observe`/`decide`/
`action` state.

## Components (`ui/src/components/`)

| Component | Role |
|-----------|------|
| `Sidebar` | Navigation, model status, new-conversation, view switching |
| `GeneralChatArea` | Default chat — persona tabs, prompt suggestions, composer |
| `ChatArea` | Device-agent chat; renders fenced code via `CodeBlock` |
| `Inspector` | Live agent-state panel (perception → plan → action) |
| `Metrics` | Performance dashboard |
| `SettingsArea` | Models (download/remove), context size, memory warnings, Privacy Lock |
| `Docs` | Markdown docs viewer (`/api/docs/:filename`) |
| `TroubleshooterGuide` | Help / troubleshooting |
| `PrivacyLock` | Passphrase lock screen for the app |
| `CodeBlock` | Syntax-highlighted code with copy (react-syntax-highlighter) |
| `ErrorBoundary` | Wraps Docs/Settings/Metrics so one render error can't blank the app |
| `AnimatedEntrance` | Entrance animation wrapper |

## State & communication

- **`ui/src/hooks/useAgentSocket.ts`** — the heart of the client. Opens the
  WebSocket, sends `start`/`chat`/`settings_update`/`preset_switch`/voice
  messages, and handles inbound `chat_stream`/`observe`/`decide`/`action`/`done`/
  `error`/`model_download_progress` events, exposing the agent + chat state to
  components. See [API.md](API.md) for the message catalog.
- **`ui/src/context/ThemeContext.tsx`** — dark/light theme.
- **REST** (`fetch`) is used for non-streaming data: the model catalog, sessions,
  notes, metrics, voice download.

### localStorage keys
| Key | Purpose |
|-----|---------|
| `quenderin_setup_complete` | Whether the WelcomeWizard has been dismissed |
| `quenderin_sidebar_open` | Sidebar collapsed/expanded |
| `quenderin_last_outage` | Last backend-outage summary (for reconnection UX) |

## Running the UI

```bash
cd ui && npm run dev        # http://localhost:5173 (hot reload)
```

The UI dev server renders the real components, but **live data needs the backend**
running on `:3000` (`npm run dashboard` from the repo root). Without it, the UI
shows its offline/disconnected state (e.g. "Loading Model… retrying").

## Design rules

The UI follows the project design system: state (`:hover`, `:focus`, active) never
changes geometry; hairline borders, no card shadows; hierarchy in weight + size;
tabular numbers; monospace for codes/metrics. Density beats decoration — this is a
developer power tool.
