# r10 — Quenderin UI/UX audit (2026-07-11)

**Lens:** IA, empty states, loading/error UX, visual consistency (50-round plan r10)
**Mode:** Inline audit + same-session fixes (Claude). All findings verified against the live app
(vite + backend, backend-down and backend-up passes).

## Findings

### U1 — Model Manager dead-ends on "Loading models..." forever — **FIXED** (High)
- **File:** `ui/src/components/SettingsArea.tsx:168`
- **Symptom:** `refreshCatalog()` swallowed failures (`catch(() => {})`); an empty catalog was
  indistinguishable from a failed fetch, so backend-down / expired-token rendered an eternal
  "Loading models...".
- **Fix:** `catalogState: 'loading' | 'error' | 'ready'`; error renders "Couldn't load the model
  catalog — is the backend running?" + **Retry**. Verified live: backend down → error + Retry;
  backend up → 13 rows.

### U2 — Metrics masked failures as "No telemetry recorded yet" — **FIXED** (Medium)
- **File:** `ui/src/components/Metrics.tsx:127`
- **Symptom:** No `res.ok` guard and no failure state — a 401/500 rendered the *empty* state,
  asserting "no runs" when the truth was "couldn't ask".
- **Fix:** `loadFailed` state + guard; failure renders "Couldn't load telemetry" + **Retry**
  (`reloadKey` re-runs the effect). Verified live both ways.

### U3 — Welcome wizard model download failed silently — **FIXED** (Medium)
- **File:** `ui/src/App.tsx:38`
- **Symptom:** A rejected kickoff just reset the spinner — click, nothing, no reason.
- **Fix:** `modelDlError` surfaces the server's error under the button (`role="alert"`); button
  relabels to "Retry Download".

### U4 — State-changes-geometry violations (`active:scale-95` ×5) — **FIXED** (Low, standing rule)
- **Files:** `App.tsx`, `GeneralChatArea.tsx` ×2, `SettingsArea.tsx` ×2
- **Fix:** Press-scale transforms removed; Save button's decorative `shadow-lg shadow-purple-500/10`
  and CodeBlock's `shadow-lg` removed (hairline-border rule). Overlay/dialog elevation shadows
  (Sidebar drawer, modals) intentionally kept — modal elevation, not card decoration.

## Accepted / open
- Sidebar recent-sessions and TasksArea capabilities fetches degrade silently to their working
  empty states — aux lists, low value in dedicated error UI (Low, accepted).
- The onboarding "Next: Setup AI Knowledge" CTA persists until a model is installed — deliberate
  no-dead-end funnel, not a bug.
