# r16 — Quenderin data-integrity audit (2026-07-11)

**Lens:** Persistence validation, partial writes, orphan rows/files (50-round plan r16)

## Findings

### D1 — Every JSON store was written non-atomically — **FIXED** (High)
- **Files:** `metrics.service.ts` (telemetry, habits compaction), `memory.service.ts`
  (trajectories ×2, corrections, clear), `session.service.ts` (both sync flush paths)
- **Symptom:** Bare `writeFile` onto the live path truncates the target the instant the write
  starts; a crash / ENOSPC / power loss mid-write leaves a half-file. The guarded readers then
  fall back to "empty" — the user's sessions / learned trajectories / telemetry silently vanish.
- **Fix:** `src/utils/atomicWrite.ts` (write `.pid.tmp` in the same dir → `rename`, cleanup on
  failure; async + sync twins). All 8 sites converted. Touched-service suites pass (57/57).

## Verified good
- **Reads are corrupt-tolerant:** telemetry `getMetrics` guards parse + `Array.isArray`; habits
  NDJSON parses per-line and skips bad lines; `listSessions` try/catches per file and skips.
- **Session ids are traversal-safe on read AND write** (`sessionPath` strips to `[a-zA-Z0-9-_]`,
  64-char cap).
- **Orphan `.tmp` residue** from a crash-before-rename is inert: session listing filters
  `*.json`; the single-file stores overwrite their temp next write.
- **Caps prevent unbounded growth:** telemetry 1000, trajectories 50 (`capForPush` — the off-by-N
  slice(1) bug was already journaled and fixed), messages-per-session capped.

## Open
- No schema validation beyond shape guards (a hand-edited but well-formed JSON could carry wrong
  types into the UI). Low value for a single-user local store; revisit if stores are ever synced.
