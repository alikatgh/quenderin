# CI / engineering audit — 2026-08-04

**Scope:** GitHub open PRs + main CI health for [alikatgh/quenderin](https://github.com/alikatgh/quenderin).  
**Verdict after fix:** main CI blockers removed; Actions Dependabot merged; major toolchain PRs deferred.

## Findings (pre-fix)

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| C1 | **P0** | `main` CI red on every recent push | **Fixed** (`79b45eb`) |
| C1a | P0 | Android JNI syntax-check: `use_mmap`/`use_mlock` removed on llama.cpp HEAD | **Fixed** — dual API |
| C1b | P0 | `npm audit --audit-level=high` — high/critical transitive deps | **Fixed** — overrides |
| C2 | P2 | Local `main` 61 commits behind `origin/main` | **Fixed** — ff pull |
| C3 | P3 | 17 open Dependabot PRs, no human feature PRs | **Partially** — 5 Actions merged |
| C4 | info | Open issues: 0 | — |

### C1a — llama.cpp API drift

CI clones `ggml-org/llama.cpp` HEAD for `scripts/check-jni-syntax.sh`. HEAD replaced:

```c
bool use_mmap; bool use_mlock;
```

with:

```c
enum llama_load_mode load_mode; // LLAMA_LOAD_MODE_MMAP == mmap, no mlock
```

Vendored `android/jni/llama.cpp` still used the bool fields. Fix: `QUENDERIN_LLAMA_LOAD_MODE` via CMake + check script; `#if` both paths in `llama_jni.cpp`. Detect with `enum llama_load_mode` / `LLAMA_LOAD_MODE_MMAP` — **not** bare `llama_load_mode` (prefix of `llama_load_model_from_file`).

### C1b — npm audit gate

Root still had high/critical after plain `npm audit fix` (sharp via `@xenova/transformers`, brace-expansion@5). UI cleared via audit fix. Root fixed with:

```json
"overrides": {
  "protobufjs": "^8.6.3",
  "brace-expansion@5": "5.0.9",
  "sharp": "0.35.3"
}
```

Avoided `npm audit fix --force` (would downgrade `@xenova/transformers` to 1.x).

## Dependabot triage

| PR | Action |
|----|--------|
| #108–#111, #113 (Actions) | **Merged** (squash) |
| #129–#131 (group minor/patch) | Rebase requested after main green |
| #116–#117, #119–#122, #124–#126 | Left open — majors / need intentional upgrade |

## Local verification (pre-push)

- JNI syntax OK against HEAD **and** vendored pin (NDK clang)
- `npm audit --audit-level=high` → 0 (root + ui)
- `tsc --noEmit`, eslint src, vitest **632/632**, golden chores ALL PASSED, ui a11y **5/5**

## Follow-up (same day, agent 100% pass)

| Action | Result |
|--------|--------|
| Merge #132, #133 (ui + root npm minor/patch) | Merged — full CI green |
| Close majors / failing Dependabot | Closed #116–#117, #119, #121–#122, #125–#126, #131 |
| Optional green majors left open | #120 Electron 43, #124 Gradle 9 (commented) |
| Delete obsolete remote branches | `wip/website-deploy-docs`, empty `feat/ship-readiness`, `security-fixes`, `readiness-phase2`, 4× `claude/*` |
| Catalog | parity OK; **13/13 URLs live** |
| Docs | `docs/HANDOFF.md` + `docs/SHIP_READINESS.md` updated for software 100% |

## Residual (owner-only — not agent-completable)

1. Facebook secrets + cover/profile images — `docs/HANDOFF.md`
2. Store console pastes / questionnaires / physical-device tok/s — `docs/SHIP_READINESS.md`
3. Optional: Electron 43 (#120), Gradle 9 (#124) with intentional smoke
4. iOS `LlamaEngine.swift` still uses `use_mmap`/`use_mlock` against **pinned xcframework** (correct until framework bump)

## Commits

- `79b45eb` — `fix(ci): green main — llama load_mode dual-API + npm audit overrides`
- `6cab16b` — audit report
- Dependabot merges #108–#113, #132–#133
