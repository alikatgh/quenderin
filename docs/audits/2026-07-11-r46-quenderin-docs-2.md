# r46 — Docs second pass (2026-07-11)

**Verdict: clean after the session's fixes; drift now has tripwires.**
- README/QUICKSTART/RUN_GUIDE: zero stale references (grep: docker, switch_model, port 3777).
- `docs/API.md` matches the code surface incl. `activeModelId` and the removed WS type;
  `FEATURES.md` model table is GENERATED with a CI `--check`; `SETUP.md` WS relics fixed (r7/r9
  close-out); `ui/README.md` rewritten; `ARCHITECTURE/BACKEND` signatures current.
- Mobile docs carry the r8 R3/R4 rationale (legacy packaging, per-SoC GPU matrix).
- Tripwires: FEATURES table drift fails CI; API.md keeps the "add message types to BOTH unions +
  this table" rule; audits ledger (`ROUND-STATUS.md`) is the single round-tracking surface.
