# r24 — Quenderin dependencies audit (2026-07-11)

**Lens:** CVEs, unpinned majors, update automation (50-round plan r24)

## Actions taken
1. **Backend:** `npm audit` — **0 vulnerabilities** (all levels).
2. **UI:** started at 5 (2 high) — all in the DEV toolchain, nothing in the shipped bundle.
   - `npm audit fix` cleared babel/picomatch/postcss.
   - **vite 6 → 8 upgraded** (with `@vitejs/plugin-react@latest`) to clear the remaining
     dev-server High (path traversal in optimized-deps `.map` handling) + esbuild Moderate
     (any-website-can-query-dev-server). Breaking change absorbed: rolldown rejects object-form
     `manualChunks` — removed entirely (which the r23 finding wanted anyway; the pin had caused
     the eager-619kB bug). Verified: `tsc` clean, production build clean, grammar bundle still
     lazy (not in `modulepreload`), dev server live with zero console errors.
3. **Automation:** CI `npm audit --audit-level=high` gate (pre-existing) + `.github/dependabot.yml`
   (Wave C-adjacent) — npm root+ui, GitHub Actions, Gradle, weekly, minor/patch grouped.

## Final state
- Root: 0 vulnerabilities. UI: **0 vulnerabilities.**
- Majors intentionally current (Express 5, Electron 40, Vite 8); Dependabot now surfaces future
  majors individually for human review.
- llama.cpp pins: desktop via node-llama-cpp ^3.2; Android JNI builds against HEAD by script —
  drift there is exercised by the CI JNI syntax-check job (Q-592).

## Dependabot triage — first live batch (2026-07-11, appended)

The Wave-C config went live immediately; 10 PRs opened. Triage (merging is human-gated):

**Green + safe to merge (grouped minor/patch, full CI matrix passed incl. APK build):**
- #118 root npm group (13 updates) · #123 android gradle group (9) · #127 ui npm group (2)

**HOLD — majors needing dedicated passes:**
- #124 gradle-wrapper 9.6 + #125 AGP 9.2 + #126 compose-bom 2026.06: a COUPLED trio (wrapper is
  pinned 8.9 to match AGP 8.5.2 per BUILD_MOBILE.md), and AGP major triggers the r8-R3
  `useLegacyPackaging` re-audit. One coordinated upgrade session, not three clicks.
- #121 @types/node 20→26: types must track the RUNTIME major (Docker/CI run Node 20) — decline
  until the runtime moves.
- #119 typescript 5.9→7.0, #122 eslint 9→10, #120 electron 40→43: majors with config/packaging
  surface; each wants its own verified upgrade commit.
