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
