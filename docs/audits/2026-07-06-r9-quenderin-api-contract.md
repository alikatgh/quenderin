---
title: "API Contract Audit — quenderin"
repo: quenderin
lens: api-contract
date: 2026-07-06
round: 9
mode: read-only
audience: Claude implementation sessions
---

# API Contract Audit — Quenderin

**Scope:** REST routes (`src/app.ts`), WebSocket protocol (`src/websocket/index.ts`), React client calls (`ui/src/`), Electron shell (`electron/main.ts`), and auth token contract (`src/security/authToken.ts`). Verified 2026-07-06.

## Executive Summary

The **documented dual surface (REST + WS) is mostly implemented**, but client/server contracts have **three high-impact gaps**: (1) **Electron hotkey intervention bypasses auth** and always 401s; (2) **two model-switch paths** (REST `POST /api/models/switch` vs WS `switch_model`) with **UI implementing neither for post-download active model change**; (3) **WS `start` payload** uses `attachments` in code but `history` in `docs/API.md`. Auth token contract is otherwise sound: mutating REST requires `X-Auth-Token`; WS upgrade validates token; `apiFetch` attaches header.

---

## Findings

### A1 — Electron intervention hotkey calls mutating REST without auth token
- **File:** `electron/main.ts:120`
- **Symptom:** `fetch('http://localhost:${PORT}/api/agent/intervene', { method: 'POST' })` — no `X-Auth-Token`; server rejects with 401 (`src/app.ts:88-93`).
- **Root cause:** Auth token added to renderer (`ui/src/lib/api.ts:16`) and preload (`electron/preload.ts:17`) but main-process hotkey uses raw `fetch`.
- **Severity:** Critical
- **Fix direction:** Pass `authToken` to Electron main (launch arg already has `--quenderin-auth=`); use same header in hotkey handler, or expose intervene via IPC to renderer `apiFetch`.
- **Tags:** `api-contract` `verified` `auth` `electron`

### A2 — Dual model-switch API: REST and WS both exist; UI uses neither for switch
- **File:** `src/app.ts:158`
- **Symptom:** `POST /api/models/switch` validates catalog + on-disk file; WS `switch_model` handler mirrors behavior (`src/websocket/index.ts:343-361`); `SettingsArea.tsx` only `download` + `delete` (`ui/src/components/SettingsArea.tsx:162-184`) — no switch call.
- **Root cause:** Download path may load model implicitly; explicit switch contract unused in UI.
- **Severity:** High
- **Fix direction:** Pick one canonical path (REST recommended for Settings); wire UI; deprecate duplicate WS type or document "WS for live dashboard, REST for settings".
- **Tags:** `api-contract` `verified` `rest` `websocket`

### A3 — WS `start` contract: code expects `attachments`; docs say `history`
- **File:** `src/websocket/index.ts:231`
- **Symptom:** `sanitizeAttachments(data.attachments)` passed to `runAgentLoop`; `docs/API.md:72` lists `history` optional field.
- **Root cause:** Doc/code drift (STILL-PRESENT from r4).
- **Severity:** High
- **Fix direction:** Update API.md; add WS integration test sending `attachments` array and asserting agent receives sanitized copy.
- **Tags:** `api-contract` `verified` `websocket`

### A4 — `GET /health` returns fields UI depends on but API.md omits
- **File:** `src/routes/health.ts:139`
- **Symptom:** Response includes `contextOptions`, `hardware`, `recommendedModelId`; UI reads them (`ui/src/App.tsx:254-256`, `SettingsArea.tsx:346`); `docs/API.md:14` only mentions `recommendedModelId`.
- **Root cause:** Health endpoint grew for hardware-adaptive UI; API table not updated.
- **Severity:** Medium
- **Fix direction:** Extend API.md health row with full JSON shape or link to TypeScript type in `ui/src/App.tsx`.
- **Tags:** `api-contract` `verified` `rest`

### A5 — `chat_response` WS payload shape not mirrored in client types/docs
- **File:** `src/websocket/index.ts:299`
- **Symptom:** Server emits `{ type: 'chat_response', message, meta, intent }`; `docs/API.md:88` lists type only; client hook must parse `meta` for telemetry UI.
- **Root cause:** Incomplete server→client catalog.
- **Severity:** Medium
- **Fix direction:** Add `ChatResponseMessage` to `ui/src/types/` and `src/types/` per project rule (`docs/API.md:107-108`).
- **Tags:** `api-contract` `verified` `websocket`

### A6 — Mutating REST auth contract is correct in UI except Electron/main gaps
- **File:** `ui/src/lib/api.ts:16`
- **Symptom:** `apiFetch` sets `X-Auth-Token`; plain `fetch` used for read-only `/health`, `/ready` (`ui/src/App.tsx:287`) — matches server intent.
- **Root cause:** Intentional split; documented in `api.ts:13-14`.
- **Severity:** Low
- **Fix direction:** Lint rule or comment block listing routes that MUST use `apiFetch`; grep CI for `method: 'POST'` without `apiFetch`.
- **Tags:** `api-contract` `verified` `auth`

### A7 — `POST /api/models/download` body contract: optional `modelId` vs UI always sends one
- **File:** `src/app.ts:143`
- **Symptom:** Server accepts omitted `modelId` → hardware fallback (`getBestInstallableModel`); UI sends explicit `modelId` (`ui/src/App.tsx:448`).
- **Root cause:** Contract allows both; consistent in practice.
- **Severity:** Low
- **Fix direction:** Document defaulting behavior in API.md; ensure mobile/desktop catalog parity tests (`npm run check:catalog-parity`).
- **Tags:** `api-contract` `verified` `rest`

---

## Contract matrix

| Endpoint / message | Server | Client consumer | Match? |
|--------------------|--------|-----------------|--------|
| `POST /api/agent/intervene` | `app.ts:113` | Electron hotkey `main.ts:120` | **No** — missing token |
| `switch_model` WS | `websocket/index.ts:343` | `ui/src/` (grep empty) | **Unused** |
| `POST /api/models/switch` | `app.ts:158` | `ui/src/` (grep empty) | **Unused** |
| `start` + attachments | `websocket/index.ts:231` | `useAgentSocket` (via socket) | Code OK, doc wrong |
| `GET /health` | `health.ts:139` | `App.tsx:287` | Partial doc |

---

*Read-only audit. No source modified.*