# r20 — Quenderin input-validation audit (2026-07-11)

**Lens:** Unbounded strings, uploads, query params (50-round plan r20)

## Findings

### V1 — No raw WS frame cap before JSON.parse — **FIXED** (Medium)
- **File:** `src/websocket/index.ts` (WebSocketServer options)
- **Symptom:** Field-level caps (goal 4k, chat 8k, attachments 10×1MB) apply AFTER
  `JSON.parse(message.toString())` — and the `ws` default `maxPayload` is ~100 MiB, so a
  token-holding client could buffer 100 MB per frame into memory first.
- **Fix:** `maxPayload: 16 MiB` (legit ceiling is 10 MB of attachments + envelope).

## Verified good
- **Every WS field is typed, sliced, and trimmed on entry:** goal `MAX_GOAL_LENGTH=4000`, chat
  `MAX_CHAT_LENGTH=8000`, presetId 50, workspace 1024, attachments capped at 10 × 1 MB with
  name length 255 (`sanitizeAttachments`).
- **Backpressure:** sends are dropped when `bufferedAmount > 1 MB` (`MAX_SEND_BUFFER_BYTES`)
  instead of ballooning the socket buffer.
- **REST bodies:** `express.json({ limit: '256kb' })`; settings validated against
  `ALLOWED_CONTEXT_SIZES`; model ids validated against the catalog (unknown id → 400);
  session/note filenames sanitized (`sessionPath`, `sanitizeNoteFilename`); calculator
  expressions capped at 500 chars; `read_file` capped at 8 kB and home+sensitive-path gated.
- **Manual resume actions** sanitized (`sanitizeManualAction` — no paste-bombs into the LLM
  context).

## Open
- None for this lens.
