# r35 — Chrome-extension audit (2026-07-11)

**Verdict: N/A.** No browser extension exists (no manifest.json of MV2/MV3 shape anywhere in the
repo). If a companion extension ever ships, start it from this plan's r35 lens (MV3, permissions
minimalism, CSP) plus the local-server token handshake design in `src/security/authToken.ts`.
