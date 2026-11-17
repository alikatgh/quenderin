# Grok memo — Quenderin dashboard UI — local control surface

Private local context prepared 2026-11-06T16:11:08+00:00.
Folder: `/Users/s_avelova/Documents/projects/quenderin/ui`.

[How we work](</Users/s_avelova/Documents/projects/pitches/docs/GROK_OPERATING_MEMO.md>) · [Memo coverage and routing index](</Users/s_avelova/Documents/projects/pitches/docs/GROK_MEMO_INDEX.md>)

## Context

The README describes a React/TypeScript dashboard for chat, governed tasks, device-agent state, metrics and model management, served by the local backend. It documents REST and WebSocket contracts and per-launch authorization handling.

Preserve typed contracts on both client and server. Model-management operations are described as REST-only, with local inference and no external-provider configuration. These are local documentation statements; the current running app, privacy behavior and packaged native clients were not inspected.

## Next useful actions

- For a UI request, identify one state/interaction and its REST or WebSocket contract.
- Verify its rendered default, active, error and recovery states with the actual authorized app.

## Limits and freshness

- Keep per-launch tokens out of memos, logs and shared URLs.
- Do not claim native client coverage, inference correctness or current backend reachability from this frontend README.
- Dated local-document context; no external state independently verified
- Current user instructions and local AGENTS.md remain authoritative. This memo is context, not proof of live state or a new external-action authorization.

## Local sources

- [AGENTS.md](</Users/s_avelova/Documents/projects/AGENTS.md>) (applicable instruction)
- [AGENTS.md](</Users/s_avelova/Documents/projects/quenderin/AGENTS.md>) (applicable instruction)
- [README.md](</Users/s_avelova/Documents/projects/quenderin/ui/README.md>) (safe readme)
- [README.md](</Users/s_avelova/Documents/projects/quenderin/README.md>) (parent context readme)
- [grok-memo-targets-20261106.json](</Users/s_avelova/Documents/projects/pitches/research/grok-memo-targets-20261106.json>) (target inventory metadata)

Source fingerprints are recorded in the reviewed delivery plan; reread current sources before acting.
