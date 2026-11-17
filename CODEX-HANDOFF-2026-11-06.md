# CODEX-HANDOFF — quenderin — 2026-11-06

> Create-only. Ghostty `ttys000` idle. Session `01a18b70`.

## What it is

Quenderin — local AI chat on personal devices (iOS released, Mac/Android pending pieces). Emails `quenderin@aulenor.com` for some apps.

**Git:** branch `codex/quenderin-reference-home-20261018`; dirty files: 8; last commit: `ea19a89 2026-10-19 07:11:44 +0800 docs: record live blog and changelog publication`

## Codex sessions

- `.../2026/10/30/rollout-2026-10-30T14-12-30-01a18b70-3917-70a3-ae30-648d3c3345fa.jsonl` (~85MB)

## What Codex did

- Night branches (2026-10-27 handoff): `night/qd-max-mobile`, `night/qd-apple-binding`, `night/qd-android-binding` pushed; **PRs not opened** — Albert decision.
- Store: **iOS 0.6.0 released**. Mac build **34** prepared but **Add for Review blocked** by automatic approval because required Mac UI test unverified — needs Albert explicit exception.
- Android: 0.6.0 bundle verified; Albert must complete **certificate / upload-key** upload + Request in Google Play console, then give activation time.
  - Play console path cited in session: developers `6289191549337108258` / app `4976280765138921912` keymanagement.
- Pitching: Honghub submitted; BPG replied wanting a call; many programme-fit emails Submitted (see pitches handoff).

## Pending decisions (exact)

1. Submit Mac build 34 **despite unverified UI test**? (yes/no exception)
2. Complete Google Play upload-key certificate steps and report activation time.
3. Open PRs for the three night branches? (`night/qd-max-mobile` recommended first in NIGHT-HANDOFF)
4. BPG call availability (also in pitches todos).
5. Quenderin funding-history answer for applications.

## Blockers

- Auto-approval review on Mac submit.
- Play Console manual certificate action.
- Dirty checkout on `codex/quenderin-reference-home-20261018`.

## Key paths

- `codex-materials/`, night worktrees historically under `/tmp/qd-*` (may be gone)
- `NIGHT-HANDOFF.md` at projects root
- Pitches attempts with projectId `quenderin`

## Next steps

1. Albert answers Mac UI-test exception + Play cert.
2. Don’t open PRs without yes.
3. Eng → Cursor.

---
