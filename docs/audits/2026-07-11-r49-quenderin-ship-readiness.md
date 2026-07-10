# r49 — Ship-readiness audit (2026-07-11)

**Verdict: READY. Zero P0/P1 blockers open.**

## The gate, run clean today
| Check | Result |
|---|---|
| `npm run build` (tsc strict + vite 8 prod) | ✅ |
| `npm test` | ✅ 588/588 (72 files) |
| `npm run lint` (src + ui, max-warnings 0) | ✅ |
| `npm audit` root + ui | ✅ 0 vulnerabilities |
| Agent parity (iOS+Android+Desktop ×19) | ✅ |
| Catalog parity (13 models ×4 surfaces, sha256) | ✅ |
| Safety-blocklist parity (34 ×3) | ✅ |
| Sampling parity (3 profiles, Swift/Kotlin/JNI) | ✅ |
| Router parity (10 ×2) | ✅ |
| FEATURES.md generated-table check | ✅ |
| Golden chore E2E | ✅ ALL PASSED |
| Docker image | builds strict (no `|| true`), binds correctly, non-root, healthchecked |

## Known-open, explicitly NOT blockers
- KV context-shift (perf ceiling on long chats) — engine project with its own plan.
- a11y Lows (focus-trap util, axe-in-CI), r37 coverage tail, r38/r44 refactor map — quality
  backlog, all documented with triggers.

## Reminder from the journal
"BUILD SUCCEEDED + codesign verify both pass on a launch-dead app" — for DMG/store artifacts,
always launch + pgrep the packaged app (scripts/build_mac_dmg.sh encodes this).
