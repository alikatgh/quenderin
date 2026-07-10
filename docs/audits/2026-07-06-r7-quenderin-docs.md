---
title: "Docs Audit — quenderin"
repo: quenderin
lens: docs
date: 2026-07-06
round: 7
mode: read-only
audience: Claude implementation sessions
---

# Docs Audit — Quenderin

**Scope:** `docs/` authoritative set vs root marketing/setup fossils (`FEATURES.md`, `ui/README.md`, `SETUP.md` if present), cross-checked against `src/`, `ui/`, `package.json`. Read `docs/BUG_JOURNAL.md` patterns first. Verified 2026-07-06.

## Executive Summary

**`docs/API.md`, `docs/DEVELOPMENT.md`, `docs/PRODUCT.md`, and rewritten `SECURITY.md` are accurate** and reflect the on-device GGUF product. However, **root-level and `ui/README.md` docs remain severely drifted** from the June r4 audit — `FEATURES.md` still describes a 3-model Llama catalog with wrong IDs, and `ui/README.md` documents a dead Ollama drag-drop UI on port 3777. **`docs/ARCHITECTURE.md` and `docs/BACKEND.md` still mis-document `runAgentLoop`'s third parameter** as `history` instead of `attachments`. `docs/README.md` indexes the good docs but does not deprecate the stale root files.

---

## Findings

### D1 — `ui/README.md` documents a nonexistent Ollama/OpenAI config UI
- **File:** `ui/README.md:18`
- **Symptom:** Describes `quenderin ui` CLI, port **3777**, drag-drop `quenderin.json`, Ollama auto-detect endpoints; actual UI is React+Vite on port **3000** (`package.json:14`, `src/index.ts`).
- **Root cause:** Orphaned doc from abandoned cloud-provider prototype; `ui/app.js` dead.
- **Severity:** Critical
- **Fix direction:** Replace with pointer to `docs/FRONTEND.md`; delete or archive `ui/README.md` and dead `ui/app.js` after `git grep` confirms zero imports.
- **Tags:** `docs` `verified` `still-present`

### D2 — `FEATURES.md` model catalog count, IDs, and vendors are wrong
- **File:** `FEATURES.md:9`
- **Symptom:** Claims "three Llama model tiers" with IDs `llama-3-8b`, `llama-3.2-3b`, `llama-3.2-1b`; live catalog has **11 models** with IDs like `llama3-8b`, `qwen3-4b` (`src/constants.ts:67`).
- **Root cause:** Marketing doc never regenerated from `MODEL_CATALOG` / `scripts/export_catalog.py`.
- **Severity:** High
- **Fix direction:** Auto-generate FEATURES §1 from catalog export; default recommendation should cite `getBestInstallableModel` not Llama-only.
- **Tags:** `docs` `verified` `still-present`

### D3 — `ARCHITECTURE.md` agent data-flow uses wrong `runAgentLoop` signature
- **File:** `docs/ARCHITECTURE.md:128`
- **Symptom:** Documents `runAgentLoop(goal, emitter, history, maxSteps)`; actual signature is `(goal, emitter, attachments, maxSteps)` (`src/services/agent.service.ts:138`).
- **Root cause:** Doc written before attachments parameter; STILL-PRESENT from r4 M1.
- **Severity:** High
- **Fix direction:** Fix signature in ARCHITECTURE + BACKEND; note WS `start` passes `attachments`, not `history`.
- **Tags:** `docs` `verified` `still-present`

### D4 — `BACKEND.md` tool list includes phantom `expression` tool
- **File:** `docs/BACKEND.md:56`
- **Symptom:** Lists `calculator, expression, datetime, …`; `expression` is a **parameter** of `calculator`, not a tool (`src/services/tools/registry.ts:42`).
- **Root cause:** Doc conflated tool name with calculator arg.
- **Severity:** High
- **Fix direction:** Regenerate tool table from `AVAILABLE_TOOLS` in registry; document `read_file` sandbox (home-dir, 8000-char cap).
- **Tags:** `docs` `verified` `still-present`

### D5 — `docs/API.md` `start` message documents `history` and `maxSteps` incorrectly
- **File:** `docs/API.md:72`
- **Symptom:** WS `start` lists optional `history`, `maxSteps`; handler uses `sanitizeAttachments(data.attachments)` and omits `maxSteps` (`src/websocket/index.ts:231-232`).
- **Root cause:** API table copied from early agent design; partial fix added `switch_model` but not `start` fields.
- **Severity:** Medium
- **Fix direction:** Replace `history` → `attachments`; note `maxSteps` honored only via CLI `--steps` (`src/index.ts:45`).
- **Tags:** `docs` `verified` `api-drift`

### D6 — `docs/API.md` under-documents `chat_response` payload
- **File:** `docs/API.md:88`
- **Symptom:** Lists `chat_response` with no fields; server sends `{ message, meta, intent }` (`src/websocket/index.ts:299`).
- **Root cause:** Server→client table is summary-only for chat path.
- **Severity:** Medium
- **Fix direction:** Document fields; clarify `intent` is a string (`intent.intent`), not `{intent, confidence, source}` object.
- **Tags:** `docs` `verified` `websocket`

### D7 — `docs/README.md` does not warn that root `FEATURES.md` contradicts `docs/API.md`
- **File:** `docs/README.md:14`
- **Symptom:** Index lists authoritative `docs/` set but repo root still contains stale `FEATURES.md`, `SETUP.md`, `QUICKSTART.md` discoverable via GitHub/README links.
- **Root cause:** No explicit deprecation layer in doc index.
- **Severity:** Low
- **Fix direction:** Add "Deprecated — do not edit" section in `docs/README.md` listing root fossils; link only `docs/` paths from main `README.md`.
- **Tags:** `docs` `verified` `onboarding`

---

## What improved since r4 (2026-06-14)

- `SECURITY.md` rewritten — accurate loopback model, no false rate-limit/Dependabot claims (`SECURITY.md:26`).
- `docs/DEVELOPMENT.md` reflects Node 20+, `npm run dashboard`, `~/.quenderin/` layout (`docs/DEVELOPMENT.md:49`).
- `docs/API.md` includes `switch_model` WS type matching server (`docs/API.md:76`, `src/websocket/index.ts:343`).

---

*Read-only audit. No source modified.*