# r37 — Test-coverage-gap audit (2026-07-11)

**Lens:** Untested critical paths (50-round plan r37)

## Added this round
1. **`tests/atomic-write.test.ts`** (4 tests) — the r16 atomic-persistence helper had no tests:
   pins old-or-new-complete-content, no temp residue, and failed-rename cleanup, async + sync.
2. **`tests/models-switch-route.test.ts`** (5 tests) — the ONE model-switch path (r9-H1) and the
   Active-badge contract had no pins: auth required, unknown id → 400 (never a fallback),
   not-on-disk → 404, catalog carries `activeModelId`.

## Remaining gaps (triaged, not closed)
| Module | Why open |
|---|---|
| `voice.service` / `ocr.service` | Hardware/native-module bound; availability guards are the testable part and are exercised indirectly. Candidate: extract pure branches. |
| `backgroundDaemon.service` | Recently redesigned (no LLM provider); worth a suite once its shape settles. |
| `utils/hardware.ts` | Pure logic — cheapest next win (tier classification + context tables). |
| `utils/logger.ts` | Low value; behavior is trivial gating. |
| Electron `main.ts` | Needs an Electron harness; covered by the packaged-app launch check (BUG_JOURNAL DMG lesson). |

False gaps from naming (verified tested): intentClassifier (`intent-classifier.test.ts`),
samplingProfiles, chatCompose, agentControl, `utils/json.ts` (via agent-parity + capability suites).
