# r39 — Ops-scripts audit (2026-07-11)

**Lens:** Maintenance scripts, destructive ops, dry-run flags (50-round plan r39)

## Fixed
- **Crash artifact (carried from r18):** `uncaughtException` now appends a last-gasp line to
  `~/.quenderin/crash.log` (sync, best-effort, never throws) before exit — previously the only
  trace died with the terminal on Electron relaunch.

## Verified
- All 19 `scripts/` entries carry purpose docstrings/headers (the parity/export/generate family
  additionally documents WHAT DRIFT it exists to catch — the repo's harness-promotion rule).
- Nothing in `scripts/` is destructive without being explicit: `refresh_model_hashes.py` mutates
  only `src/constants.ts` hashes and says so; the DMG/deploy shell scripts operate on build
  output dirs; no script touches user data (`~/.quenderin`) at all.
- CI-invoked scripts (`check_*`) are read-only by construction; `generate_features_models.py`
  has an explicit `--check` (no-write) mode for CI.

## Open
- None. (The i18n translate_* scripts are dormant with the r13 stance — fine.)
