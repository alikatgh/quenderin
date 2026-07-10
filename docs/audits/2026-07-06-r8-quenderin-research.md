---
title: "Research Audit — quenderin"
repo: quenderin
lens: research
date: 2026-07-06
round: 8
mode: read-only
audience: Claude implementation sessions
---

# Research Audit — Quenderin

**Scope:** Dependency currency, on-device LLM best practices (llama.cpp, node-llama-cpp), mobile packaging research, Express/Electron conventions, and cross-platform twin-parity patterns from `BUG_JOURNAL.md`. Verified 2026-07-06.

## Executive Summary

Quenderin aligns with **2025–2026 on-device LLM research**: local GGUF via `node-llama-cpp`, chat-template correctness, KV-cache context-shift (audited separately), and hardware-adaptive model selection. Research debt concentrates on **(1)** desktop agent automation brittleness (acknowledged in README); **(2)** **twin-platform parity** (Android Kotlin vs iOS Swift vs desktop TS); **(3)** **Express 5 + Electron 40** stack freshness without automated CVE gate beyond manual `npm audit`. Android `useLegacyPackaging = true` shows prior research on APK native-lib scanning was applied.

---

## Findings

### R1 — `node-llama-cpp` ^3.2.0 is current generation; chat-template research is implemented on mobile, desktop relies on library
- **File:** `package.json:51`
- **Symptom:** Desktop uses `node-llama-cpp` 3.x; `BUG_JOURNAL.md:87-92` documents raw User/Assistant prompts causing max-token ramble on Android — fixed via `llama_chat_apply_template`.
- **Root cause:** Instruct models require template fidelity; research lane split across platforms.
- **Severity:** High
- **Fix direction:** Verify desktop `llm.service.ts` uses same template path as mobile for Qwen/Llama-3 families; add parity test with shared prompt fixtures.
- **Tags:** `research` `verified` `inference` `llama-cpp`

### R2 — KV strict-prefix reuse cliff is a known research failure mode
- **File:** `docs/BUG_JOURNAL.md:97`
- **Symptom:** Long chats full-reprefill when oldest turn drops — TTFT promise inverts exactly when chats grow.
- **Root cause:** Prefix-only reuse incompatible with sliding context window without `llama_memory_seq_rm` shift.
- **Severity:** High
- **Fix direction:** Implement context-shift per `docs/audits/2026-07-01-kv-cache-reuse-cliff.md`; validate greedy-decode parity after shift.
- **Tags:** `research` `verified` `performance` `llama-cpp`

### R3 — Android JNI packaging research applied; desktop lacks equivalent native scan issue
- **File:** `android/app/build.gradle.kts:81`
- **Symptom:** `useLegacyPackaging = true` set so directory-scan dlopen paths work (`BUG_JOURNAL.md:61-65`).
- **Root cause:** AGP default mmap-from-APK breaks ggml backend enumeration.
- **Severity:** Medium
- **Fix direction:** Document in `docs/BUILD_MOBILE.md` why legacy packaging is required; re-audit when upgrading AGP.
- **Tags:** `research` `verified` `android` `llama-cpp`

### R4 — GPU offload must be SoC-gated per llama.cpp Vulkan heterogeneity research
- **File:** `docs/BUG_JOURNAL.md:49`
- **Symptom:** Blind `n_gpu_layers = 999` crashes or regresses on Mali/Xclipse; Adreno proven.
- **Root cause:** Vulkan driver quality varies; research says measure tok/s, don't guess.
- **Severity:** Medium
- **Fix direction:** Keep `GpuOffloadPlanner` default CPU; publish per-SoC matrix in `docs/MOBILE_PERFORMANCE_101.md`.
- **Tags:** `research` `verified` `mobile` `gpu`

### R5 — Express 5.2 + Electron 40 are bleeding-edge; no Dependabot configured
- **File:** `package.json:49`
- **Symptom:** `express: ^5.2.1`, `electron: ^40.6.0`; `SECURITY.md:71` notes no CI audit gate / Dependabot.
- **Root cause:** Rapid stack upgrades for features; research on Express 5 breaking changes (router async errors, req.host) not centralized.
- **Severity:** Medium
- **Fix direction:** Add `.github/dependabot.yml` + `npm audit` in CI (already in `npm run check:14`); pin majors in lockfile review.
- **Tags:** `research` `verified` `dependencies` `security`

### R6 — Desktop coordinate-based agent loop is research-validated brittle; symbolic id targeting is the right lane
- **File:** `README.md:21`
- **Symptom:** README honestly lists coordinate brittleness, timing races, canvas UIs; improvements claim view-level symbolic actions.
- **Root cause:** LLM+UI automation research consensus: perception→plan→verify loops need stable selectors, not x/y.
- **Severity:** Low
- **Fix direction:** Keep agent experimental per `docs/PRODUCT.md`; do not market device control in store apps; invest in `UiVerifier` + `waitForUiIdle` patterns.
- **Tags:** `research` `verified` `agent` `architecture`

---

## Dependency / convention snapshot

| Dependency | Version | Research note |
|------------|---------|---------------|
| node-llama-cpp | ^3.2.0 | Align with llama.cpp bXXXX pin in android submodule |
| @xenova/transformers | ^2.17.2 | Embeddings for RAG; offline after first model fetch |
| vitest | (dev) | Fast unit tests; not substitute for Android runtime regex (`BUG_JOURNAL.md:73`) |
| ws | ^8.19.0 | Standard; origin gate required (`src/websocket/index.ts:125`) |

---

*Read-only audit. No source modified.*