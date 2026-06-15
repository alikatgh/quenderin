---
title: "Quenderin — Deep Correctness Audit (Verified)"
repo: quenderin
lens: correctness
date: 2026-06-14
round: 6
---
All confirmed. L2 confirmed (15s monitor + per-load). The "OK" notes are accurate. selectBestModel sorts smallest-first per its own docstring (intentional).

I have enough to finalize. Let me do one last verification on the H5 buffer-zeroing nuance and the C1 fallback-cast detail by re-checking the XML fallback in agent.service (already read: line 260 `action as AgentAction['action']`). Confirmed.

Now compiling the final verified report.

---

# Quenderin — Deep Correctness Audit (Verified)

Read-only audit of `/Users/svetlana/Documents/projects/quenderin`. Scope: backend (`src/`), the React socket hook (`ui/src/hooks/useAgentSocket.ts`), and Electron entry points. Every finding below was re-checked against the actual source. Verdicts: **CONFIRMED**, **CONFIRMED (refined)**, or **DOWNGRADED/REMOVED** with reasoning. TypeScript types do not catch any of these (the action union is bypassed via casts).

---

## CRITICAL

### C1. Agent can never execute `swipe`, `back`, `home`, or `enter` — actions the prompt explicitly tells the LLM to emit — CONFIRMED
**Files:** `src/services/agent.service.ts:21-28` (SYSTEM_PROMPT) vs `src/services/agent/actionExecutor.ts:33-112`; `src/types/index.ts:52-60` (AgentAction union).

The system prompt (agent.service.ts:21-28) advertises exactly these actions: `click`, `input`, `swipe`, `back`, `home`, `enter`, `done`. `ActionExecutor.execute()` only handles `'done'` (37), `'click'`/`'input'` (47), and `'scroll'` (98); everything else hits `emitter.emit('error', 'Unknown action type: ${actionType}')` and returns `false` (111-112). So:
- When the LLM emits `swipe`/`back`/`home`/`enter` (as instructed), execution fails every time.
- `scroll` *is* handled by the executor and both providers, but the prompt never advertises `scroll` (verified: grep found no `scroll` in agent.service.ts), so the model is unlikely to emit it.
- `AgentAction.action` is typed `'click' | 'input' | 'scroll' | 'done'` (types/index.ts:53) — it omits `swipe`/`back`/`home`/`enter`. The XML fallback casts a raw string in (`action as AgentAction['action']`, agent.service.ts:260), and the JSON path casts via `actionObj as AgentAction` (line 303), so the compiler cannot flag the mismatch.

The agent's advertised gesture/navigation vocabulary is dead on arrival. **Fix:** unify the vocabulary across prompt + `AgentAction` union + executor — either map `swipe→scroll` and drop the key actions, or add real executor handlers for `swipe`/`back`/`home`/`enter` that call the existing provider methods (see C2).

### C2. `IDeviceProvider.pressKey()` is dead code — no key events (back/home/enter) ever reach the device — CONFIRMED
**Files:** `src/services/providers/android.provider.ts:178-187`, `src/services/providers/desktop.provider.ts:136-148`; `src/types/index.ts:42`.

`pressKey` is fully implemented on both providers (Android maps enter→66, back→4, home→3; desktop maps back→escape, home→command, else `keyTap`). Grep for `pressKey` across `src/`, `ui/`, `electron/` returns only the interface declaration and the two implementations — **zero call sites**. Combined with C1, the agent literally cannot press Back/Home/Enter, dismiss dialogs, or submit forms via keyboard. **Fix:** wire `pressKey` into `ActionExecutor` once C1's vocabulary is unified.

---

## HIGH

### H1. Download "resume" corrupts byte accounting when the server answers 200 to a `Range` request — CONFIRMED
**File:** `src/services/llm.service.ts:707-786`.

On resume, `receivedBytes` is set to the partial file size (716) and a `Range: bytes=N-` header is sent (717). `isResume = response.status === 206` (753). If the server responds **200** (ignoring Range — common with CDNs/redirects), the write stream correctly opens truncating (`isResume ? {flags:'a'} : undefined`, 761), **but `receivedBytes` is never reset to 0**. The loop then counts from the stale partial size (772), so progress `(receivedBytes / totalBytes) * 100` (774) starts well above 0 and can exceed 100% for the whole download. There is also no validation that a 206 response's `Content-Range` start equals `receivedBytes` — a mismatched 206 would append at the wrong offset and corrupt the GGUF. **Fix:** when `status !== 206`, reset `receivedBytes = 0` before the read loop; when 206, parse and verify `Content-Range`.

### H2. `verifyAction` mis-handles element id `0` (a valid id), reporting unverified success — CONFIRMED
**File:** `src/services/agent/uiVerifier.ts:126-131`.

Element ids start at `0` (`uiParser.service.ts:73`, `id: idCounter++` from 0). The guard at line 129 is `if (!targetIdRaw || (actionType !== 'click' && actionType !== 'input'))`. Both the JSON path (`JSON.parse` yields numeric `0`) and the XML path (`parseInt(id,10)` yields numeric `0`, agent.service.ts:262) produce a numeric `0`, for which `!0 === true`. So any click/input on the first/root element short-circuits to the generic `[Success] Executed click.` (130) and skips the real pre/post existence check (136-153). The agent's self-healing feedback is silently wrong for that element. `ActionExecutor` at line 50 uses the correct `!== undefined && !== null` check — the codebase is internally inconsistent. **Fix:** replace `!targetIdRaw` with `targetIdRaw === undefined || targetIdRaw === null`.

### H3. `safeCalculate` silently ignores trailing/garbage tokens — returns wrong answers without error — CONFIRMED
**File:** `src/services/tools/calculator.ts:213-227`.

`parser.parseExpression()` (222) is called once and the result returned; the parser never verifies `this.pos === this.tokens.length`. So tokenizable-but-unconsumed trailing input is silently dropped:
- `"2 3"` → tokens `[2,3]` → `parseExpression` returns `2`, the `3` is discarded.
- `"(1+2) 4"` → returns `3`, the `4` is dropped.
- `"2 ) ("` → returns `2`.

(`"5 + 2 garbage"` actually throws in the tokenizer on `garbage` via the unknown-identifier path, so that specific example in the draft is wrong — but the trailing-token class of bug is real.) For a calculator whose value is correctness, returning a partial result is a defect. **Fix:** after `parseExpression()`, throw `CalculatorError('Unexpected trailing input')` unless the parser consumed all tokens.

### H4. Trajectory memory cap is ineffective — only ever drops one record — CONFIRMED
**File:** `src/services/memory.service.ts:113-115` and `137-139`.

```ts
if (records.length > 50) { records = records.slice(1); }
records.push(...)
```
`slice(1)` drops a single element regardless of overflow, so at 51 it trims to 50 then pushes back to 51 — it oscillates at 51 and never enforces "last 50." The corrections store (187-189) uses the correct `slice(-(MAX-1))` form, so this is internally inconsistent. (Note: the file does not grow unbounded — it self-limits to ~51 — so the draft's "unbounded-ish" hedge is overstated; the real bug is the cap is off-by-N and the form disagrees with the corrections path.) **Fix:** `records = records.slice(-(50 - 1))` before pushing.

### H5. Manual voice capture runs against a stale/empty buffer with no availability guard — CONFIRMED (refined)
**File:** `src/services/voice.service.ts:136-149`.

`manualCaptureStart`/`manualCaptureStop` guard only on `STATE` (`if (this.STATE !== 'IDLE')` / `!== 'RECORDING'`), **not on `this.voiceAvailable`/`this.recorder`**. When Picovoice/recorder failed to load (common on unsupported platforms), `audioLoop()` returns early (86) and `STATE` stays `'IDLE'`, so `manualCaptureStart` flips it to `'RECORDING'` and `manualCaptureStop` calls `processAudioBuffer()`. With no frames ever appended, `currentSampleIndex` is `0`, so `audioBuffer.slice(0, 0)` (154) yields an empty clip → an empty WAV → an empty/garbage transcription, plus a wasted whisper inference if present.

Refinement to the draft: the buffer is a zero-initialised `Int16Array` and the slice uses `currentSampleIndex`, so the failure is an *empty/zero-length* clip, not "padded with stale samples." The draft's second sub-bullet (manual capture only works while the wake loop polls) is correct as a design limitation but is minor — when the recorder loaded, `audioLoop` runs continuously and appends frames during `'RECORDING'`, so manual capture does function. **Fix:** guard both methods with `if (!this.voiceAvailable || !this.recorder) return;`.

---

## MEDIUM

### M1. `findSimilarGoal` mutates the freshly-parsed records array via `.reverse()` — CONFIRMED (latent)
**File:** `src/services/memory.service.ts:167` — `records.reverse().find(...)`. `records` is re-parsed from disk each call, so no cross-call corruption today; latent if any future code reads `records` after this line. Prefer `[...records].reverse()`.

### M2. UI parser builds bogus elements for the non-UI `hierarchy` root / container nodes; child ids precede parents — CONFIRMED
**File:** `src/services/uiParser.service.ts:48-93`.

`traverse` is invoked on `rawTree.hierarchy` (92) and unconditionally builds a `UIElement` for *every* node — including the synthetic `hierarchy` root and any container with no `bounds`/`class` → elements with empty text/class and `center {0,0}`. These inflate `elements.length`, which drives the OCR fallback threshold `< 5` (`uiVerifier.ts:88`) and the idle-detection length comparison (`uiVerifier.ts:54`), and add `{0,0}` click targets. Also, because `idCounter++` runs *after* recursing into children (51-56 before 73), children get lower ids than parents. **Fix:** skip nodes lacking a `class`/`bounds`; assign the id before recursing if document order is intended.

### M3. Streaming control-token stripping can't strip tokens split across chunks — CONFIRMED
**Files:** `src/websocket/index.ts:234-269`, `src/services/llm.service.ts:908-916`, `src/utils/stripControlTokens.ts:29-36`.

`onTextChunk` applies `stripControlTokensWithOptions(chunk, {trim:false})` per token (llm.service.ts:909). Multi-character markers (`<|im_end|>`, `</s>`, `<|eot_id|>`) that span token boundaries won't match within a single chunk, so fragments can slip to the client mid-stream; only the final assembled `result.text` is fully cleaned (951). The `<tool_call>` path has bespoke split-aware tail-holdback buffering (index.ts:256-264) but the other control tokens do not. (Severity tempered: many GGUF runtimes surface `<|im_end|>` etc. as suppressed special tokens, so real-world leakage is intermittent — hence Medium, not High.) **Fix:** apply the same tail-holdback to the control-token set, or buffer a small sliding window before forwarding.

### M4. `MAX_CHAT_TURNS` is derived from the user-requested context size, not the effective one — CONFIRMED
**File:** `src/services/llm.service.ts:808-811` vs `402-406`, `69-92`.

`MAX_CHAT_TURNS` uses `this.currentSettings.contextSize` (809). But the model is loaded with `effectiveCtx = resolveContextForSituation(...)` (402), which in degraded mode returns `HW.contextFloor` (76) — as low as **128/256/512** (hardware.ts:170/184/198). So with a user setting of 2048 the reset budget is ~20 turns against, say, a 256-token window — guaranteeing context overflow / KV thrash long before the reset (875) fires, exactly the OOM it was meant to prevent. **Fix:** persist the resolved `effectiveCtx` on the instance and base `MAX_CHAT_TURNS` on it.

### M5. `note_save` can write a file literally named `.md` when the title is all-special / non-ASCII — CONFIRMED
**File:** `src/services/tools/handlers.ts:113-124`.

`safeTitle = title.replace(/[^a-zA-Z0-9\s\-_]/g,'').trim().replace(/\s+/g,'_').slice(0,80)` (119). A title like `"!!!"` or `"日本語"` reduces to `""`, producing `path.join(NOTES_DIR, '.md')` (121) — a hidden file that collides across all such titles and silently overwrites. The non-empty check at 116 validates the *raw* title, not the sanitized one. Compounding: `note_list` filters on `f.endsWith('.md')` (line 129), so `.md` (which ends with `.md`) would also surface oddly. **Fix:** after sanitizing, if `safeTitle === ''` fall back to a timestamp/uuid name (or reject).

### M6. Agent "CHAT" branch emits the answer as a `status` log, not a chat message, and never persists it — CONFIRMED
**Files:** `src/services/agent.service.ts:151-161`, `ui/src/hooks/useAgentSocket.ts:81-82`.

When intent is classified as chat inside the agent loop, the answer is delivered via `emitter.emit('status', response)` (159). In the UI hook, `status` messages are rendered as plain status log lines (`entry.message = data.message`, useAgentSocket.ts:81-82), not assistant chat bubbles, and (unlike the websocket chat path at index.ts:271) the response is never persisted via `sessionService.addMessage('assistant', ...)`. The answer reaches the user but in the wrong channel and is lost from history. **Fix:** route through a chat event and persist to the session.

---

## LOW

### L1. `process.on('uncaughtException')` hard-exits the whole server — CONFIRMED
**File:** `src/server.ts:30-33`. Any uncaught exception anywhere calls `process.exit(1)`, killing the dashboard and all sessions. Fragile for a long-running local agent. Consider logging + graceful degradation for non-fatal subsystems.

### L2. `availableMemBytes()` shells out synchronously (`vm_stat`/`df`/PowerShell/wmic) on hot paths — CONFIRMED
**Files:** `src/utils/memory.ts:24-154`; called from the memory-pressure monitor every 15 s (`llm.service.ts:185-200`), per model-load (369), `/health` (health.ts:145), and `constants.ts:198`. `execSync` blocks the event loop; on macOS/Windows this adds latency spikes. Cache for a few seconds or use async exec.

### L3. `df -k "$dir" | tail -1` field parsing is locale/layout-fragile — CONFIRMED (Low)
**File:** `src/services/llm.service.ts:631-641`. `parts[3]` assumes a fixed column layout; localized `df` output can shift fields. Wrapped in best-effort try/catch (643), so it only weakens the disk check, never crashes.

### L4. `chatTurnCount` increment is skipped when generation throws after a successful first prompt — CONFIRMED (cosmetic)
**File:** `src/services/llm.service.ts:997` (success path only); the catch at 1002 rethrows without incrementing. A failed-then-retried turn under-counts, slightly delaying the session reset. Cosmetic given M4 is the real turn-budget issue.

### L5. Voice download leaves a partially-extracted model dir on failure, which then short-circuits future downloads — CONFIRMED
**File:** `src/app.ts:196-238`. The unzip pipeline logs errors (231) but leaves a partial directory; the existence check at line 201 (`fs.stat(targetPath)`) then believes the model is present and returns "already exists." Extract to a temp dir and rename on success.

### L6. `model_download_progress` payload shape disagrees with its type — CONFIRMED
**Files:** `src/types/index.ts:35` declares `(payload: { progress: number })` but emits include `{ progress, modelId }` (`llm.service.ts:669, 776`). Harmless at runtime (extra field), but the type is wrong and the UI can't distinguish per-model progress if two downloads overlap. Tighten the type to include `modelId`.

---

## Findings I could NOT confirm / corrections to the draft

- **H3 example correction:** the draft's `"5 + 2 garbage"` case does **not** silently return a partial result — `garbage` is an unknown identifier and the tokenizer throws (`calculator.ts:67`). The trailing-token bug is real (`"2 3"`, `"(1+2) 4"`, `"2 ) ("`), so H3 stands, but drop that example.
- **H4 overstatement:** the file does not grow "unbounded-ish" — it self-caps at ~51 entries. The genuine bug is the off-by-N cap and the form disagreeing with the corrections path. Severity HIGH is borderline; arguably MEDIUM since data integrity isn't lost, just the bound is wrong by one and old trajectories accumulate to 51 instead of 50.
- **H5 mechanism correction:** the stale clip is *empty/zero-length*, not "padded with stale samples" — the buffer is zero-initialised and sliced to `currentSampleIndex` (0). Guard is the right fix; the impact statement should say "empty/wasted transcription."
- **M3 severity:** kept at MEDIUM (was MEDIUM in draft) — correct, given special-token suppression makes leakage intermittent in practice.

## Notes on things that look wrong but are OK (verified)
- `new WebSocketServer({ server })` with no `path` (index.ts:58) accepts upgrades on any path — `path` defaults to undefined and `shouldHandle` returns true. Intentional.
- Calculator `parseExponent` right-associativity (130) and unary precedence (137-143) are correct.
- `selectBestModel` sorting smallest-first (llm.service.ts:106-107) is intentional per its own docstring ("Prefer responsiveness first").
- Corrections-store eviction (memory.service.ts:187-189) is correct — contrast with the buggy trajectory cap in H4.
- `process.on('unhandledRejection')` (server.ts:27-29) only logs (does not exit) — correct; only `uncaughtException` hard-exits (L1).

---

## Recommended next steps (priority order)

1. **C1 + C2 together** — unify the action vocabulary (prompt ↔ `AgentAction` union ↔ `ActionExecutor`) and wire `pressKey`. This is the headline: the autonomous agent cannot perform gesture/navigation/keyboard actions today. Pick one source of truth and add a typecheck/test that the prompt's advertised actions are a subset of the executor's handled set.
2. **H1** — reset `receivedBytes = 0` on non-206 responses and validate `Content-Range` on 206, to stop progress corruption / GGUF corruption on resume.
3. **H2** — fix the `!targetIdRaw` guard in `uiVerifier.ts:129` to a null/undefined check so element id `0` is verified.
4. **H3** — enforce full-token consumption in `safeCalculate` (`isAtEnd()` + throw on trailing input).
5. **H4 / M4** — fix the trajectory cap form (`slice(-(50-1))`) and base `MAX_CHAT_TURNS` on `effectiveCtx`, not the user setting (the latter is a real OOM risk on constrained hardware).
6. **H5, M5, M6** — add the voice availability guard; fall back to a timestamp filename when `safeTitle` is empty; route the agent CHAT answer through a chat event + persist it.
7. **Lows (L1–L6)** — schedule opportunistically; L1 (hard-exit) and L5 (partial-extract short-circuit) are the most user-visible.

No fixes were applied — this audit is read-only. All file:line citations above were verified against the current working tree.
