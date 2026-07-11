# r38 — Refactor-opportunities audit (2026-07-11)

**Lens:** Dedup clusters, extraction candidates (50-round plan r38). Documented, deliberately not
churned — each is safe to do opportunistically when its file is next touched.

1. **Done:** `firstJsonObject` (2 copies → `src/utils/json.ts`); `NumberRender` ported once
   (calculator.ts). **2026-07-11:** the H9 resume-decision extracted from the 230-line
   `downloadModel` into pure `modelDownloadPlan.ts` (+10 tests) — the tested seam that makes the
   larger llm.service download-manager extraction (r44) safe to do later.
2. **UI error+Retry block** appears 3× (SettingsArea catalog, Metrics, wizard) with the same
   shape — extract `<RetryState message onRetry>` when a 4th consumer appears (rule of three is
   exactly met; the variants still differ in layout, so extraction is optional not overdue).
3. **`SettingsArea.tsx` (~900 lines)** hosts settings + model manager + notes + memory +
   diagnostics — 4 natural child components. Split when the next feature lands there.
4. **`sanitize-then-slice` idiom** on WS fields is hand-rolled per field; a `capString(v, max)`
   helper would read better (7 call sites).
5. **Session store sync-fs style** (`session.service`) vs async everywhere else — works (and is
   race-free by virtue of sync), but converting to the async atomic writer would unify the
   persistence idiom. Low priority; do only with its tests open.
