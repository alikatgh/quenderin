---
title: "Research Audit (VERIFIED) — Quenderin"
repo: quenderin
lens: research
date: 2026-06-14
round: 5
---

Confirmed: `getRecommendedModelIdForTotalRam` returns `'llama32-1b-q2'` (Q2_K) **only when `totalRamGb < 1.5`** (line 181). So R-L11's "Shipping Q2_K to the weakest devices is where the agent will be least reliable" is **accurate** — devices under 1.5GB RAM auto-get the Q2_K model. The claim holds (I was wrong to doubt it; the MODEL_RECOMMENDATIONS table is a separate path, but the `<1.5GB` branch does route to Q2_K).

I have now verified every local code fact. The CVE/web-research claims (specific CVE IDs, fixed versions, advisory URLs) I cannot fully verify without web access, and several have future-dated IDs (CVE-2026-*) consistent with the mid-2026 environment date — I'll mark the external CVE specifics as "cited, not independently re-verified here" rather than asserting them as confirmed. The local mechanics that make each finding real (vulnerable installed versions, missing checks) are all confirmed via `npm audit`.

Here is the final verified report.

---

# Research Audit (VERIFIED) — Quenderin (`/Users/svetlana/Documents/projects/quenderin`)

**Verification method:** Every local code/dependency fact was re-checked with Read/Grep + `npm audit`/`npm ls` (read-only). External CVE IDs, fixed-version numbers, and advisory URLs are reproduced from the draft and the cited sources; I did **not** have web access to re-fetch them, so they are marked *[cited — not re-verified online]*. The vulnerable **installed versions** and the **missing local mitigations** that make each finding exploitable are all locally confirmed.

## Verdict summary
- **No findings removed as false positives.** Every finding maps to a real, locally-confirmed code condition.
- **Corrections applied** to file paths, action-type names, and severity framing (details inline).
- `npm audit` locally confirms **21 vulns (5 moderate / 14 high / 2 critical)** — matches the draft exactly. The 2 criticals are `protobufjs` and `simple-git` — confirmed.

### Local-fact corrections vs. the draft
1. **R-C1 bind detail:** `server.listen(selectedPort, callback)` at `server.ts:192` has **no host arg** (confirmed) → Node binds the unspecified address (all interfaces). The port probe at `server.ts:71` binds `'::'` explicitly (all IPv6, confirmed). The draft says "binds `0.0.0.0`" — substantively correct (all interfaces) but the literal default is the IPv6 unspecified address, not the string `0.0.0.0`.
2. **R-C1 download is catalog-driven, not arbitrary-URL:** `POST /api/models/download` accepts only a `modelId` resolved against the hardcoded `MODEL_CATALOG`; the fetch URL is `entry.url` (a pinned HuggingFace `https://` URL), **not** attacker-supplied. The RCE chain therefore requires a **TLS-MITM, a malicious/compromised HF mirror, or HF-side poisoning** — not a trivially injectable URL. Severity stays CRITICAL given no integrity check + all-interfaces bind, but the precondition must be stated honestly. **Confirmed: zero SHA-256/integrity check** in `downloadModel` (`llm.service.ts:649-802`); the only validation is a `size > 100MB` sanity check.
3. **R-M7 action types:** The agent's `AgentAction.action` union is **`'click' | 'input' | 'scroll' | 'done'`** (`types/index.ts:53`) — there is **no `keyevent`/destructive-key agent action**. The draft's "before `type`/destructive keyevents" overstates the surface: only `input` (which calls `deviceProvider.type()`) and `click` flow through `checkSafety`. Corrected below.
4. **Confirmed-good path citation:** the `read_file` home-confinement guard is at **`src/services/tools/handlers.ts:25-29`** (`isInsideHome`), not `src/services/agent/handlers.ts`. Logic is sound.
5. **Catalog contents (R-L11):** catalog also includes **Qwen2.5-Coder-7B** and **Meta-Llama-3-8B**, not only the models the draft listed. Minor.

---

## Environment snapshot (locally verified)
- Node **v26.3.0**, npm **11.16.0**. `package.json` engines `node>=20.0.0`. ✅
- `npm audit`: **21 vulns — 2 critical / 14 high / 5 moderate.** ✅
- Installed: `node-llama-cpp@3.16.2`, `@xenova/transformers@2.17.2`, `express@5.2.1`, `ws@8.19.0`, `fast-xml-parser@5.4.1`, `electron@40.6.0`, `electron-builder@26.8.1`. ✅
- UI: `react@18.3.1`, `vite@5.x` (root transitively pulls `vite@8.0.16` via `vitest@4.1.8` — confirmed), `tailwindcss@3.4.19`. ✅

---

## CRITICAL

### R-C1. Unverified GGUF download + llama.cpp GGUF-parser RCE advisories = a MITM/supply-chain RCE chain
**Files (verified):** `src/services/llm.service.ts:649-802` (fetch→stream to disk, **no integrity check** — confirmed), `src/constants.ts:65-176` (catalog entries have `url`, **no `sha256`** — confirmed), `src/server.ts:192` (no host arg → all interfaces — confirmed), `src/app.ts:120-127` (`POST /api/models/download`, **unauthenticated** — confirmed).

The downloaded GGUF is parsed by `node-llama-cpp`'s bundled llama.cpp GGUF loader. Cited GGUF-parser memory-corruption→code-execution advisories *[cited — not re-verified online]*: **CVE-2025-53630** (GHSA-vgg9-87g3-85w8), **CVE-2026-27940** (incomplete-fix follow-up), **CVE-2025-49847** (GHSA-8wwf-w4qm-gpqr).

**Confirmed chain:** all-interfaces bind → any LAN host can POST the unauthenticated download route → bytes streamed to `~/.quenderin/models/*.gguf` with no SHA-256 → loaded by the GGUF parser. **Precondition (corrected):** the URL is catalog-pinned HTTPS, so exploitation needs TLS-MITM / malicious mirror / HF poisoning — not arbitrary-URL injection. The README's "100% offline / no external calls after initial download" thesis is undercut by this trusting bootstrap fetch.

**Fix:** (1) pin `sha256` per catalog entry, verify before `loadModel()`, refuse on mismatch; (2) bind loopback: `server.listen(selectedPort, '127.0.0.1', …)` (and stop probing all interfaces at `:71`); (3) add auth to mutating `/api/*` routes; (4) keep `node-llama-cpp` current (R-C2/R-L12).

### R-C2. Two critical dependency CVEs present, both fixable
**File:** `package.json` (transitive — locally confirmed via `npm ls`).
- **protobufjs@6.11.4 — CRITICAL** (audit confirms `protobufjs | critical | Arbitrary code execution`). Reached via a **runtime** path: `@xenova/transformers@2.17.2 → onnxruntime-web@1.14.0 → onnx-proto@4.0.4 → protobufjs@6.11.4` — `npm ls protobufjs` confirms this exact chain. `@xenova/transformers` is genuinely used (`memory.service.ts:4,92`). CVE-2026-41242 / GHSA-xq3m-2v4x-88gg, fixed in 7.5.5 / 8.0.1 *[cited — not re-verified online]*. Mitigation requires upgrading the transformers/onnxruntime stack (or migrating to `@huggingface/transformers`).
- **simple-git@3.32.2 — CRITICAL** (audit confirms `simple-git | critical | blockUnsafeOperationsPlugin bypass`). Chain `node-llama-cpp@3.16.2 → simple-git@3.32.2` — confirmed by `npm ls simple-git`; one patch from the fixed line. CVE-2026-28292, fixed 3.32.3 *[cited — not re-verified online]*.

**Fix:** `npm audit fix`; upgrade transformers/onnxruntime to clear protobufjs; `overrides` to force `simple-git ≥3.32.3`; add `npm audit --audit-level=high` to the `check` script (currently `check` = typecheck+lint+test only — confirmed, no audit gate).

---

## HIGH

### R-H3. `electron@40.6.0` below patched line + missing window/navigation hardening
**File:** `package.json:70` (confirmed installed 40.6.0; audit flags `electron | high`). Cited CVEs *[cited — not re-verified online]*: CVE-2026-34779 (AppleScript injection, fixed 40.8.0), CVE-2026-34778 (service-worker IPC spoof, fixed 40.8.1), CVE-2026-34769 (watch).
**Locally confirmed:** `src/electron/main.ts:46-49` sets `contextIsolation:true`, `nodeIntegration:false` (good), `loadURL` at `:54`, but **no `setWindowOpenHandler`, no `will-navigate` guard, no `sandbox:true`** (grep confirms absence).
**Fix:** Electron ≥40.8.1; add `setWindowOpenHandler(()=>({action:'deny'}))`, a `will-navigate` localhost allow-list, and `sandbox:true`.

### R-H4. `fast-xml-parser@5.4.1` — entity-expansion DoS; parser ingests device-controlled XML
**Files:** `package.json:43` (installed 5.4.1; audit flags `fast-xml-parser | high | numeric entity expansion bypassing all entity expansion limits` — confirmed). `src/services/uiParser.service.ts:5-8,20` constructs `new XMLParser({ ignoreAttributes:false, attributeNamePrefix:"" })` with **no `processEntities:false`** (confirmed — entity expansion left at the v5 default). The XML is **device-sourced**: `android.provider.ts:107-108,202-203` runs `uiautomator dump` and pulls `/sdcard/window_dump.xml` — a malicious on-device app can craft it.
Cited: CVE-2026-33036 (numeric-entity bypass, critical, incomplete fix of CVE-2026-26278) *[cited — not re-verified online]*; the installed 5.4.1 is still flagged HIGH locally.
**Fix:** upgrade to the patched 5.x line **and** set `processEntities:false` when parsing device XML (a UI tree needs no entity expansion).

### R-H5. Build-chain HIGH CVEs (`tar`, `tmp`, `esbuild`, `lodash`, `@xmldom/xmldom`) — dev/build-only
**File:** `package.json:71` (`electron-builder@^26.8.1`). All locally confirmed HIGH in `npm audit`: `tar` (hardlink/symlink path traversal), `tmp` (path traversal via prefix/postfix), `esbuild` (via `tsx`), `lodash` (`_.template` code injection + prototype pollution), **`@xmldom/xmldom` (XML injection via unsafe CDATA serialization — new vs r1, confirmed in audit)**. Not request-path; release-time supply-chain risk.
**Fix:** upgrade `electron-builder` to its latest 26.x+ to dedupe; `overrides` for any laggards; run `electron-builder` in CI only.

### R-H6. `ws@8.19.0` — uninitialized-memory disclosure (audit severity: MODERATE)
**File:** `package.json:50`, `src/websocket/index.ts`. **Correction:** `npm audit` rates this **moderate**, not high (`ws | moderate | Uninitialized memory disclosure`). The draft already flags it as "moderate→treat as high for a network server," which is a judgment call, not a misstatement — but the underlying advisory severity is moderate. The WS server is reachable on all interfaces (R-C1), so elevating operational priority is defensible.
**Fix:** `npm update ws` to the patched 8.x; add the loopback bind + Origin/Host checks.

---

## MEDIUM

### R-M7. Agent safety = a 5-word English substring blocklist; no role separation; no mandatory confirmation
**Files (verified):** `src/services/agent/actionExecutor.ts:12` (`BLOCKLIST = ['pay','delete','password','buy','confirm purchase']`), `:16-31` (`text.includes(lowerWord)` substring match over `el.text`/`el.contentDesc`/`inputText`), `src/services/agent/promptBuilder.ts:11,30` (device `textRepresentation` + attachments + goal concatenated into one prompt with only plain-text markers, **no instruction/data role delimiters** — confirmed), `src/app.ts:93` (`/api/agent/intervene` exists — reactive, not a pre-action gate).
**Corrections:** (1) the only gated agent actions are `click`/`input` — there is **no `keyevent` agent action** (`types/index.ts:53`), so "destructive keyevents" is inaccurate; the real gap is that **only `input` text and clicked-element text are substring-checked**. (2) README:34 explicitly advertises this 5-word blocklist as "Safety Sandboxing" — the claim oversells a substring filter.
Substantive gaps confirmed: English-only substring match misses localized labels ("Pagar"/"Löschen"/"支付"), icon-only buttons, split labels; false-positives on benign "buy"/"pay"; untrusted screen text concatenated with instructions = the indirect-injection shape. Cited OWASP Agentic / LLM01 guidance *[cited — not re-verified online]*.
**Fix:** (1) mandatory user-confirmation gate before any `input` (and any future destructive action) on screens the agent didn't originate; (2) replace the substring blocklist with a per-task positive allow-list + explicit instruction/data delimiters in the prompt; (3) correct README:34's "Safety Sandboxing" claim.

### R-M8. Remote embedding model fetched at runtime, no pinning — contradicts the offline thesis
**File (verified):** `src/services/memory.service.ts:8` (`env.allowLocalModels = false`), `:91-92` (`pipeline('feature-extraction','Xenova/all-MiniLM-L6-v2')`). With `allowLocalModels=false`, the MiniLM model is fetched **remotely from the HF hub at runtime**, no checksum, no local fallback. README:46 claims "100% locally and offline… no external network calls after initial model download" — **directly contradicted** (confirmed). Also a correctness bug: RAG silently breaks when genuinely offline.
**Fix:** bundle MiniLM (or download-once-verify with pinned SHA), set `allowLocalModels = true`, point at the local copy.

### R-M9. No rate limiting, no `helmet`; SECURITY.md claims rate limiting that does not exist
**Files (verified):** grep for `helmet`/`rate-limit`/`rateLimit`/`express-rate` across `src/` + `package.json` returns **nothing** (confirmed absent). `src/app.ts:48-49` sets a hand-rolled `Content-Security-Policy` header only. **`SECURITY.md:54` states "Rate limiting is enabled on the UI server" and `SECURITY.md:60` states "Rate limiting (100 requests per 15 minutes)" — both false** (confirmed; no middleware exists). This is a documentation-vs-reality security defect, not just a missing feature.
**Fix:** add `helmet()` (replaces hand-rolled CSP, adds `frame-ancestors`/`object-src`/`base-uri`), add `express-rate-limit` on `/api/*`, and either implement the claimed controls or correct SECURITY.md.

---

## LOW / Currency notes

### R-L10. UI stack a major behind convention (React 18 / Vite 5; root Vite 8 via vitest)
**File:** `ui/package.json` — `react@18.3.1`, `vite@^5.3.4`, `tailwindcss@3.4.19` (confirmed). Root transitively carries `vite@8.0.16` via `vitest@4.1.8` (confirmed) — the 8-vs-5 split is a real smell. Not a security issue.
**Fix:** schedule React 19 + Vite 7 + Tailwind 4; consolidate the Vite version.

### R-L11. Q2_K is auto-recommended to <1.5GB-RAM devices — quality trap (confirmed)
**File:** `src/constants.ts:36` (`Q2_K` = quality "Low", "noticeable quality loss", `recommended:false`), `:167-174` (`llama32-1b-q2`, Q2_K), `:181` (`getRecommendedModelIdForTotalRam` returns `'llama32-1b-q2'` when `totalRamGb < 1.5`). So the weakest devices **are** auto-routed to Q2_K — the draft's claim holds (the `MODEL_RECOMMENDATIONS` table at `:47-56` is Q4_K_M throughout, but the `<1.5GB` short-circuit overrides it). Q2_K degrades agentic/JSON output most.
**Fix:** raise the floor to Q3_K_M, or gate Q2_K behind an explicit "reduced quality" opt-in.

### R-L12. `node-llama-cpp@3.16.2` — pin/track so the bundled llama.cpp carries GGUF fixes
**File:** `package.json:44` (`^3.2.0`, installed 3.16.2 — confirmed). Because the GGUF-parser CVEs (R-C1) live in the embedded llama.cpp, pin and periodically bump; add a `docs/` note to re-check the bundled commit on each upgrade.

---

## Confirmed-good (no action — locally verified)
- `spawn('adb', args[])` argv-array, no shell (`android.provider.ts:30`) — confirmed correct; host-side shell injection not reachable. (Device-shell `input text` passes text as one arg, `:157`.)
- Hand-written calculator, no `eval`/`Function` (`tools/handlers.ts` / `tools/calculator.ts`) — confirmed.
- `contextIsolation:true` / `nodeIntegration:false` (`electron/main.ts:48-49`) — confirmed.
- `read_file` home-confinement (`isInsideHome`, **`src/services/tools/handlers.ts:25-29`** — path corrected from draft) — mechanism sound; policy is broad (should denylist `~/.ssh`/`~/.aws`/`.env`).
- WS input caps + `ALLOWED_CONTEXT_SIZES` allow-list (`websocket/index.ts:17-20,168,213`; `constants.ts:278`) — confirmed.

---

## Recommended next steps (priority order)
1. **R-C1 + R-C2 (highest leverage):** loopback bind + auth on mutating routes + per-catalog SHA-256 verified before `loadModel()`; upgrade transformers/onnxruntime (protobufjs) and force `simple-git ≥3.32.3`. Add `npm audit --audit-level=high` to the `check` script.
2. **R-H3:** Electron ≥40.8.1 + `setWindowOpenHandler`/`will-navigate` allow-list/`sandbox:true`.
3. **R-H4 / R-H6:** `fast-xml-parser` to the patched line with `processEntities:false`; `ws` patch bump.
4. **R-H5:** dedupe/override the `electron-builder` chain (`tar`/`tmp`/`lodash`/`@xmldom/xmldom`/`esbuild`); build in CI only.
5. **R-M7:** mandatory confirmation gate before device `input`; replace the substring blocklist with an allow-list + instruction/data delimiters; correct README:34.
6. **R-M8 / R-M9:** bundle+verify the embedding model (restore true offline); add `helmet` + `express-rate-limit`, and fix the false rate-limit claims in SECURITY.md:54,60.
7. **R-L10/L11/L12:** schedule React 19/Vite 7/Tailwind 4; raise the quant floor off Q2_K for <1.5GB devices; pin/track `node-llama-cpp`.

**Caveat on external claims:** all CVE IDs, fixed-version numbers, and advisory/source URLs above are reproduced from the draft and were **not re-verified against live sources in this read-only pass** (no web access used). The vulnerable installed versions and missing local mitigations underpinning every finding **are** locally confirmed via `npm audit`/`npm ls` and code reads. Before acting, confirm the exact fixed versions against the upstream advisories.

**Key files:** `/Users/svetlana/Documents/projects/quenderin/src/services/llm.service.ts`, `/Users/svetlana/Documents/projects/quenderin/src/constants.ts`, `/Users/svetlana/Documents/projects/quenderin/src/server.ts`, `/Users/svetlana/Documents/projects/quenderin/src/app.ts`, `/Users/svetlana/Documents/projects/quenderin/src/services/agent/actionExecutor.ts`, `/Users/svetlana/Documents/projects/quenderin/src/services/agent/promptBuilder.ts`, `/Users/svetlana/Documents/projects/quenderin/src/services/agent.service.ts`, `/Users/svetlana/Documents/projects/quenderin/src/services/memory.service.ts`, `/Users/svetlana/Documents/projects/quenderin/src/services/uiParser.service.ts`, `/Users/svetlana/Documents/projects/quenderin/src/services/providers/android.provider.ts`, `/Users/svetlana/Documents/projects/quenderin/src/services/tools/handlers.ts`, `/Users/svetlana/Documents/projects/quenderin/src/electron/main.ts`, `/Users/svetlana/Documents/projects/quenderin/package.json`, `/Users/svetlana/Documents/projects/quenderin/ui/package.json`, `/Users/svetlana/Documents/projects/quenderin/SECURITY.md`, `/Users/svetlana/Documents/projects/quenderin/README.md`.
