# r45 — Deadcode second pass (2026-07-11)

**Verdict: clean.**
- Unused-export sweep over `src/utils/*`: zero dead exports (every exported symbol has ≥1
  consumer outside its module).
- June orphans stay deleted (config.ts, generateId.ts, runToolLoop); the WS `switch_model`
  removal left no dangling references (`model_switched` gone from the client union).
- `maxConcurrentHeavyOps` remains as /health telemetry only (accepted, r22).
- The i18n `translate_*.py` scripts are dormant-by-design (r13 stance), not dead.
