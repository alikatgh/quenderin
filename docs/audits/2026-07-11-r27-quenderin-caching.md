# r27 — Quenderin caching audit (2026-07-11)

**Lens:** Stale cache, poisoning, TTL, bounds (50-round plan r27)
**Verdict: clean — every cache is bounded, keyed sanely, and staleness-aware.**

## Inventory verified
| Cache | Bound | Staleness/poisoning posture |
|---|---|---|
| Intent classifier results | `MAX_CACHE_SIZE=200`, oldest-evict, bound asserted by tests | keyed by normalized input; worst case is a wrong-intent replay of the same text |
| Prompt-builder corrections | single last-UI-state entry | invalidated when UI text changes (the C4 fix) |
| `availableMemBytes` memo | 1 s TTL | advisory value; slightly-stale by design (Q-505) |
| Skill memory (`agent-skills.json`) | `MAX_GOAL_LEN=300`, `MAX_TOOLS=40`, `MAX_INPUT_LEN=120` — hard caps so a hand-edited/poisoned file can't bloat the planner prompt | validated on read; only successful runs write |
| LLM KV cache | engine-managed; mission cache released exactly once per run (tested) | strict-prefix reuse cliff documented as the open engine project (r23) |
| UI catalog/metrics fetches | no client cache (fresh fetch + explicit Retry) | diagnostics uses `cache: 'no-store'` |
| HTTP responses | no server-side response caching (correct for a local dynamic API) | static assets served by express.static defaults |

## Notes
- No cache is shared across users (single-user app) — the classic poisoning vector (one user's
  input served to another) does not exist here. The skill-memory caps are the right paranoia:
  that file IS user-writable state that feeds the planner prompt.
