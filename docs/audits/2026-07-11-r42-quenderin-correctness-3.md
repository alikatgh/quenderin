# r42 — Correctness third pass (2026-07-11)

**Scope:** this session's changes, adversarially.

- **atomicWrite:** guarantees ATOMICITY (old-or-new complete), deliberately not DURABILITY
  (no fsync before rename — a power cut can lose the newest write but never truncates; right
  trade for advisory local stores, and now pinned by tests incl. failed-rename cleanup).
  Windows `rename` overwrite semantics confirmed (libuv uses MOVEFILE_REPLACE_EXISTING).
- **Active badge gating** (`isDownloaded && id === activeModelId`) — verified against the
  server's boot-pins-a-default behavior; route contract now test-pinned (r37).
- **PrismAsync swap:** plain-text `<pre>` until the grammar loads is the intended progressive
  behavior; no API change (drop-in from the same package).
- **Parity fixes:** all 19 vectors green ×3 platforms; full suite 588/588.
- No STILL-PRESENT items from r22 changed state.
