# API Reference

Quenderin exposes a **REST API** (request/response, under `/api/*`) and a
**WebSocket protocol** (streaming, for chat and the agent loop). All of it is
local — served from `localhost`, no external calls.

## REST endpoints

Base: `http://localhost:3000` (the dashboard server).

### Health & diagnostics
| Method | Path | Purpose |
|--------|------|---------|
| GET | `/health` | Liveness + `recommendedModelId` for the device |
| GET | `/ready` | Readiness (serving / starting / error) |
| GET | `/diagnostics` | Detailed diagnostics (hardware, model, services) |

### Metrics
| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/metrics` | Performance telemetry (tok/s, TTFT, RAM, loaded model) |

### Models
| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/models/catalog` | All catalog models + `isDownloaded` status, plus `activeModelId` |
| POST | `/api/models/download` | Download a model. Body `{ modelId? }`; defaults to the hardware recommendation (kept in sync with `/health`) |
| POST | `/api/models/switch` | Switch the active model at runtime (the ONE switch path — the unused WS `switch_model` twin was removed after it drifted). Body `{ modelId }` |
| DELETE | `/api/models/:modelId` | Remove a downloaded model |

### Agent
| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/agent/intervene` | Pause / inject a correction into a running agent loop |
| POST | `/api/agent/resume` | Resume a paused agent loop |

### Sessions
| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/sessions` | List sessions |
| GET | `/api/sessions/:id` | Fetch one session |
| DELETE | `/api/sessions/:id` | Delete a session |
| GET | `/api/sessions/:id/export` | Export a session |

### Notes & memory
| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/notes` | List notes (saved via the `note_save` tool) |
| GET | `/api/notes/:filename` | Read a note |
| DELETE | `/api/notes/:filename` | Delete a note |
| GET | `/api/memory/trajectories` | List stored agent trajectories (RAG memory) |
| DELETE | `/api/memory/trajectories` | Clear stored trajectories |

### Misc
| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/presets` | Assistant personas |
| GET | `/api/tools` | Available chat tools |
| GET | `/api/templates` | Prompt templates |
| GET | `/api/docs/:filename` | Serve a docs markdown file (in-app docs viewer) |
| POST | `/api/voice/download` | Download the Picovoice voice model bundle |

## WebSocket protocol

Connect to the dashboard's WebSocket. Messages are JSON with a `type` field.
Input is validated server-side (length caps, attachment count/size limits).

### Client → Server

| `type` | Purpose | Key fields |
|--------|---------|-----------|
| `start` | Start an agent objective | `goal`, optional `attachments`, `maxSteps` |
| `chat` | Send a chat message | `message`, optional `attachments` |
| `settings_update` | Change runtime settings | e.g. `contextSize` (one of `ALLOWED_CONTEXT_SIZES`) |
| `preset_switch` | Switch assistant persona | `presetId` |
| `manual_voice_start` | Begin push-to-talk voice capture | — |
| `manual_voice_stop` | End voice capture | — |

### Server → Client

| `type` | Meaning |
|--------|---------|
| `session_started` | An agent run / chat session has begun |
| `status` | Human-readable status update (e.g. "Loading model…") |
| `log` | A log line for the UI/inspector |
| `chat_stream` | A streamed token chunk of a chat reply |
| `chat_response` | The final, complete chat reply |
| `observe` | Agent loop: current perception of the screen |
| `decide` | Agent loop: the LLM's planned symbolic action |
| `action` | Agent loop: the action being executed |
| `action_required` | Agent paused — needs human confirmation |
| `done` | Agent loop finished successfully |
| `model_download_progress` | Download progress `{ progress, modelId }` |
| `preset_changed` | Confirms a persona switch |
| `error` | An error to surface to the user (never silently swallowed) |

### The agent event sequence

A typical objective streams: `session_started` → (`observe` → `decide` →
`action`)\* → `done`. An `error` can end it at any point; `action_required`
pauses it pending `/api/agent/resume` or an `intervene`.

## Adding a message type

New WebSocket message types **must** be added to the TypeScript interfaces in both
directions (client `ui/src/types/` and server `src/types/`) — this is a project
rule. Keep this table in sync.
