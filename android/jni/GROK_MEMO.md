# Grok memo — Quenderin Android JNI — native boundary

Private local context prepared 2026-11-06T16:11:08+00:00.
Folder: `/Users/s_avelova/Documents/projects/quenderin/android/jni`.

[How we work](</Users/s_avelova/Documents/projects/pitches/docs/GROK_OPERATING_MEMO.md>) · [Memo coverage and routing index](</Users/s_avelova/Documents/projects/pitches/docs/GROK_MEMO_INDEX.md>)

## Context

`android/jni` is a native integration scope under Quenderin. No scoped README or handoff in this inventory established its current JNI entry points, build state or runtime coverage; the parent’s native release and provenance instructions remain the route for later work.

Treat any future JNI change as a platform boundary requiring exact library/source provenance and clear ownership of types, memory and failure paths. The module’s existence does not establish that a model has run on Android, that an AAB is signed, or that a store update is available.

## Next useful actions

- Identify the requested native boundary and read its maintained platform instructions when authorized.
- Verify the exact packaged library and affected Android behavior before a release claim.

## Limits and freshness

- Source integration, compilation, device inference and store publication are separate evidence.
- This memo does not start NDK compilation, devices, downloads or release actions.
- Dated local-document context; no external state independently verified
- Current user instructions and local AGENTS.md remain authoritative. This memo is context, not proof of live state or a new external-action authorization.

## Local sources

- [AGENTS.md](</Users/s_avelova/Documents/projects/AGENTS.md>) (applicable instruction)
- [AGENTS.md](</Users/s_avelova/Documents/projects/quenderin/AGENTS.md>) (applicable instruction)
- [README.md](</Users/s_avelova/Documents/projects/quenderin/android/README.md>) (parent context readme)
- [grok-memo-targets-20261106.json](</Users/s_avelova/Documents/projects/pitches/research/grok-memo-targets-20261106.json>) (target inventory metadata)

Source fingerprints are recorded in the reviewed delivery plan; reread current sources before acting.

## Subordinate context kept here

53 reviewed subordinate/reference folders use this safe memo rather than receiving a private file in their payload. Exact routes and reasons are in the coverage index.
