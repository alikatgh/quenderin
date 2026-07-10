# r50 — Consolidation: the 50-round plan, closed out (2026-07-11)

**All 50 rounds are DONE for quenderin** — r1–r6 (June wave), r7–r9 (Grok wave, items closed
2026-07-11), r10–r50 (Claude inline waves, 2026-07-11). Every round has a report in this
directory; `ROUND-STATUS.md` is the ledger of record.

## What the 2026-07-11 waves fixed (severity-ordered highlights)
1. One flaky WS client could kill the server (r14) · 2. Docker deployment couldn't connect at
all + false-green builds (r19/r41) · 3. Non-atomic persistence truncating user data (r16) ·
4. 3 real cross-platform divergences the moment desktop joined the parity bijection (r7-wave) ·
5. 619 kB dead-weight on first paint from a chunk-pin (r23/r24) · 6. Dead-end/lying UI states
(r10) · 7. Screen-reader-silent transcripts (r11) · 8. Dual switch path + unpinnable model
(r9-H1) · 9. UI dev-toolchain CVEs → 0 via vite 8 (r24) · 10. Doc drift → generated + tripwired
(r7/r46).

## The open backlog, in recommended fix order
| # | Item | Source | Trigger/shape |
|---|------|--------|---------------|
| 1 | ~~KV context-shift~~ **DONE — already merged** (`0350f55`, discovered 2026-07-11; cross-machine re-baseline). Residual: S23 throughput A/B as post-merge measurement | r8-R2 / r23 / r47 | Device-gated measurement only |
| 2 | ~~`utils/hardware.ts` unit tests~~ **DONE 2026-07-11** — `classifyTier` extracted pure; 19 tests (band edges, knob invariants, env overrides) | r37 | — |
| 3 | SettingsArea 4-way split (`<RetryState>` extraction **DONE 2026-07-11** — shared by catalog + telemetry failures, `role="alert"`) | r38 / r44 | Split: when the next feature touches Settings |
| 4 | llm.service download-manager extraction | r44 | When the next download feature lands |
| 5 | ~~Focus-trap util~~ **DONE 2026-07-11** (`useFocusTrap` — initial focus, Tab wrap both directions, restore-on-close; wired to WelcomeWizard + TroubleshooterGuide, live-verified). axe-core in CI still open | r11 | axe: when UI component tests land |
| 6 | ~~backgroundDaemon test suite~~ **DONE 2026-07-11** — 5 tests on the visual-diff core (first-frame, static, half-change, rotation reset, unreadable-path degrade) | r37 | — |
| 7 | Per-IP throttles + WS connection caps | r26 | ONLY if LAN mode becomes supported |
| 8 | i18n extraction (all three twins together) | r13 | Only with a real second-locale plan |

## Standing invariants the plan leaves behind (the actual "world-class" part)
- Twin drift fails CI, not audits: agent 19×3, router 10×2, catalog 13×4, safety 34×3, sampling ×3.
- Docs that can drift are generated (FEATURES table) or tripwired (API.md rule, this ledger).
- Persistence is atomic; stores are capped; reads are corrupt-tolerant.
- Every store/telemetry write path and both build pipelines fail loudly (no `|| true` anywhere).
- The bug journal's pattern section is the pre-debugging checklist; entries land in the same
  commit as fixes — that discipline held for every wave here.
