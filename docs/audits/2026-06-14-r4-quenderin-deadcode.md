---
title: "Deadcode Audit — Quenderin — VERIFIED FINAL REPORT"
repo: quenderin
lens: deadcode
date: 2026-06-14
round: 4
---
Confirmed: the actual preset-switch method is `setPreset` (line 224), not `setActivePreset`. The draft's L4 fix suggestion names a nonexistent method. All line references in the draft (daemon.service.ts 99 lines, config.ts:63, toolLoop.ts:67-100) check out.

I have a complete, verified picture. Every finding C1 through L6 is confirmed deadcode. The corrections to the draft are: (1) SETUP.md:120 is correct, not dead-referencing; (2) `setActivePreset` should be `setPreset` in L4's fix. Here is the final report.

# Deadcode Audit — Quenderin — VERIFIED FINAL REPORT

READ-ONLY audit of `/Users/svetlana/Documents/projects/quenderin`. No files modified. I independently re-verified every finding in the draft by grepping/reading live source. **All 18 findings (C1–L6) are CONFIRMED true positives.** I corrected two inaccurate *recommendations/claims* in the draft (noted inline as `[CORRECTION]`) and downgraded none. No false positives found. One missed nuance added.

## Summary
- **4 fully orphaned modules**, zero importers: `src/config.ts`, `src/utils/generateId.ts`, `src/services/daemon.service.ts`, `src/types.ts`.
- **1 orphaned legacy UI file**: `ui/app.js`.
- **1 duplicate Electron entry point** where the feature-complete file is dead and the stale one ships (C1).
- **7 dead exported functions/consts**, **3 write-only dead class fields**.
- Swift/Kotlin/website sides clean (informational only).
- No bug journal exists; 5 prior audits in `docs/audits/` corroborate many items.

---

## CRITICAL

### C1 — Duplicate Electron entry point: feature-complete file is dead, stale file ships
**Files:** `src/electron/main.ts` (166 lines, full) vs `electron/main.ts` (root, 48 lines, stale). CONFIRMED.
`package.json:11` `main = "dist/electron/main.js"`; `tsconfig.json` `rootDir:"./"`, `outDir:"./dist"`, `include:["src/**/*","electron/**/*"]`. Therefore root `electron/main.ts → dist/electron/main.js` (**ships**) and `src/electron/main.ts → dist/src/electron/main.js` (**dead, never referenced**).
The dead `src/electron/main.ts` has: `findFreePort` (dynamic port, :14), `startDashboardServer(PORT, false)` (:33), tray (:63), global shortcuts (:75/:87), app menus (:118/:137), `ready-to-show` (:56). The shipped root file hardcodes `startDashboardServer(3000)` + `loadURL('http://localhost:3000')` — 500s/blank window if port 3000 is busy. Signature `startDashboardServer(port=3000, openBrowser=true)` (`server.ts:84`) confirms both calls are valid.
**[CORRECTION to draft]** The draft claims "the docs (ARCHITECTURE.md:49, BACKEND.md:13-14, SETUP.md:120) all describe `src/electron/main.ts`." Verified: only **`docs/BACKEND.md:13`** and **`docs/ARCHITECTURE.md:49`** reference the dead `src/electron/main.ts`. **`SETUP.md:120` and `docs/ARCHITECTURE.md:27` correctly reference the shipped root `electron/main.ts`** — they are *not* describing the dead file.
**Fix:** Pick one entry. Move the good `src/electron/main.ts` content into root `electron/main.ts` (or repoint `package.json main` → `dist/src/electron/main.js`) and delete the loser. Then fix `BACKEND.md:13` + `ARCHITECTURE.md:49`. (Prior audit `2026-06-14-r2-quenderin-correctness.md` flagged the port symptom.)

---

## HIGH (4 fully orphaned modules — zero importers, zero risk to delete)

### H1 — `src/config.ts` fully orphaned (73 lines) — CONFIRMED
Exports `QuenderinConfig`, `loadConfig`, `saveConfig`, `createDefaultConfig` (:63). Zero imports in `src/`, `ui/`, `tests/`, `electron/`. App is configured via env vars + `currentSettings` in `LlmService` instead. (Prior: `2026-06-14-r3-quenderin-arch.md`.)

### H2 — `src/utils/generateId.ts` fully orphaned (17 lines) — CONFIRMED
Exports `generateId`, `generateShortId`. Zero usages repo-wide. App uses `randomUUID()` / `Date.now()` directly.

### H3 — `src/services/daemon.service.ts` dead service module (99 lines) — CONFIRMED
Exports `ObservationData` (:6), `DaemonService` (:14). Never instantiated. Live code uses `BackgroundDaemonService` (`server.ts:13,119`). Docs `ARCHITECTURE.md:111` + `BACKEND.md:65` still list `daemon.service.ts` — fix those too.

### H4 — `src/types.ts` orphaned flat type module (44 lines) — CONFIRMED
Exports `OllamaModel`, `OllamaTagsResponse`, `QuenderinError`, `ConfigError`, `ProviderError`, `GenerationError`. Zero references. Live types are in the *different* file `src/types/index.ts`. Ollama types are inapplicable (app is GGUF/node-llama-cpp). The name collision with the live `src/types/index.ts` is a real maintenance hazard — deleting removes it.

---

## MEDIUM

### M1 — `runToolLoop()` dead — CONFIRMED (`toolLoop.ts:67-100`)
Exported, never called. `llm.service.ts:954-982` re-implements the loop inline, importing `hasToolCalls/parseToolCalls/formatToolResults/stripToolCalls` directly from `toolLoop.js` (`llm.service.ts:46`) and bypassing the `runToolLoop` orchestrator. **Fix:** delete `runToolLoop`, or refactor the inline loop to call it (DRY).

### M2 — `classifyWithLlmFallback()` dead — CONFIRMED (`intentClassifier.ts:103`)
Exported LLM-fallback classifier, never called. Only the sync regex `classifyIntent` is used (`websocket/index.ts:223`, `agent.service.ts:134`). Low-confidence inputs silently default to `chat` (`intentClassifier.ts:96`, `confidence:'low', source:'default'`). The IMAGE/MATH/CODE fallback branches are only reachable through this dead path. **Fix:** wire it (pass an `llmClassify` adapter) or delete it.

### M3 — `MemoryService.saveCorrection()` dead; corrections feature half-wired — CONFIRMED (`memory.service.ts:177`)
`saveCorrection` has zero callers. Its read counterpart `findRelevantCorrections` IS called (`promptBuilder.ts:21`), but nothing ever writes — `corrections.json` is initialized to `[]` (`memory.service.ts:52-53`) and stays empty forever. The Xenova-embedding correction subsystem does real work over permanently-empty data. **Most consequential after C1: a feature that looks implemented but can never produce a non-trivial result.** **Fix:** wire `saveCorrection` into the manual-intervention/resume flow, or remove the dead write path + the read path it feeds.

### M4 — `LLM_MODEL_PATH` exported const dead — CONFIRMED (`constants.ts:284`)
No consumers (only its own definition + the comment at :282). The loaded model is chosen by `selectBestModel`/`activeModelId` in `llm.service`. The `process.env.LLM_MODEL_PATH` override it reads is therefore inert. **Fix:** delete the export (and the misleading :281-283 comment), or honor it.

### M5 — `QUANTIZATION_INFO` exported const dead — CONFIRMED (`constants.ts:30-43`)
14-line quant table (`Q2_K`…`Q8_0`), referenced only at its own definition. Ported from "off-grid-mobile," never consumed. **Fix:** delete, or surface in the model-catalog API.

---

## LOW

### L1 — Write-only dead field `LlmService.activeModelEntry` — CONFIRMED (`llm.service.ts:147`)
Assigned `:305` (null) and `:390` (`selected.entry`); never read (verified no cross-file reads). Comment claims "Cached reference … for per-request decisions" but nothing reads it. **Fix:** remove field + 2 assignments, or actually use it.

### L2 — Write-only dead field `LlmService.lastActivityTimestamp` — CONFIRMED (`llm.service.ts:162`)
Assigned `:281`; never read. Idle behavior uses a plain `setTimeout`, so the timestamp is vestigial. **Fix:** remove field + assignment.

### L3 — Dead private field `AgentService.currentGoal` — CONFIRMED (`agent.service.ts:66`)
`private currentGoal: string = ""` — the *only* occurrence in the repo; never read or written elsewhere (goal is a method param throughout `runAgentLoop`). **Fix:** delete the field.

### L4 — `clearIntentCache()` dead — CONFIRMED (`intentClassifier.ts:152`)
Exported cache-clear helper, no callers. Cache is already LRU-bounded (`MAX_CACHE_SIZE=200`), so no leak — pure dead surface. **[CORRECTION to draft]** The draft suggests calling it "in `LlmService.setActivePreset`" — **that method does not exist**. The actual preset-switch method is **`LlmService.setPreset` (`llm.service.ts:224`)**. Wire it there on preset switch, or delete.

### L5 — `ui/app.js` orphaned legacy file (255 lines) — CONFIRMED
Vanilla-JS provider-setup screen (Ollama/OpenAI model the app no longer uses). Not referenced by any HTML: `ui/index.html:13` loads `/src/main.tsx` (React), `public/index.html:10` loads the built bundle. Predates the React rewrite. **Fix:** delete. (Prior: `2026-06-14-r1-quenderin-security.md`.)

### L6 — `modelManifestJSON()` dead — CONFIRMED (`manifest.ts:18`)
Exported, no callers. Only `buildModelManifest` + `MANIFEST_VERSION` are used (`tests/manifest.test.ts`). The JSON it produces is generated by `scripts/export_catalog.py` instead. **Fix:** delete, or use it for a node-side cross-check of the Python output.

### L7 — `createDefaultConfig()` — subsumed by H1
`config.ts:63`; deleting the whole H1 module covers it. Not a separate action.

---

## Informational (verified NOT deadcode / intentional)

- **`generateCode()` (`llm.service.ts:813`)** — zero call sites repo-wide (no `.generateCode(` invocation anywhere), BUT it is a mandated member of the `ILlmProvider` interface (`types/index.ts:47`), alongside `generalChat`/`generateAction`. Intentional interface surface, not dead. (Sibling `generalChat`/`generateAction` ARE called; `generateCode` is the one interface method not yet exercised — worth a note but correctly excluded from deadcode.)
- **`apple/` Swift, `android/` Kotlin** — clean. Mock/scripted engines are test/preview fixtures; the example tools and downloaders are registered in the real apps. (Accepted from draft; this audit's verification was scoped to the TS tree per the draft's own depth — Swift/Kotlin re-grep not independently repeated.)
- **`website/main.js`, `gradient.js`** — referenced by `website/index.html`. **`public/assets/index-*.js|css`** — committed build artifact served by `app.ts` static, intentionally tracked. **`src/types/vendor.d.ts`** — ambient declarations, not imported by design.
- **"Legacy" comments** in `constants.ts`, `stripControlTokens.ts`, `memory.ts`, `llm.service.ts` are live fallback paths, not dead code.

---

## Recommended next steps (cheapest, highest-confidence first)
1. **Delete the 5 fully orphaned files** (zero importers, zero risk): `src/types.ts`, `src/config.ts`, `src/utils/generateId.ts`, `src/services/daemon.service.ts`, `ui/app.js`.
2. **Resolve C1** (Electron duplicate) — highest impact; also fixes a real shipping bug (blank window on busy port 3000). Then fix `docs/BACKEND.md:13` + `docs/ARCHITECTURE.md:49` (note: `SETUP.md:120` and `ARCHITECTURE.md:27` are already correct — leave them).
3. **Decide M3** (`saveCorrection`) — wire it or remove the half-feature; misleadingly "implemented."
4. **Remove dead exports/fields** (M1, M4, M5, L1–L4, L6); decide M2 (wire LLM fallback or delete). For L4, target `setPreset` (not `setActivePreset`).
5. **Update docs** (`ARCHITECTURE.md:111`, `BACKEND.md:65` for the deleted `daemon.service.ts`).

Per project Delete Audit Protocol: every item above is source implying work — confirm before `rm`. Per the global bug-journal rule, no `docs/BUG_JOURNAL.md` exists yet — bootstrap with `/init-bug-journal` and append an entry in the same commit as any fix (especially C1, which fixes a real bug).
