# r44 — Architecture second pass (2026-07-11)

**Verdict: boundaries hold; two documented pressure points.**

- **Layering verified:** routes (`app.ts`) → services → capability layer (blocklist → consent →
  approval → ledger pipeline) → providers (mac/android/desktop). Twin logic lives behind shared
  vectors + parity CI rather than a shared runtime — an explicit, now-mechanically-enforced choice.
- **Single-user process-global services** (June H18): still the architecture, still correct for
  the product (one local user); the WS session-ADOPT fix (Q-596) removed the sharp edge.
- **Pressure point 1:** `SettingsArea.tsx` aggregates 4 concerns (r38 split plan).
- **Pressure point 2:** `llm.service.ts` (~1.4k lines) owns lifecycle + download + chat + sampling;
  cohesive but at the size where the next feature should extract (download manager is the natural
  seam — `modelIntegrity` already is).
