# Ultracode adversarial bug hunt — 2026-07-11

**Method:** Workflow `ultracode-bughunt` — 6 subsystem-scoped sonnet finders → 6 batched
adversarial sonnet verifiers (refute-by-default) → opus synthesis. 13 agents, ~819k tokens.
Surfaces: agent-loop, capability-safety, model-download, network-auth, persistence, providers.

**Independent re-verification:** each finding was re-read against the cited code by the main
loop before any fix; per-finding disposition (fixed / downgraded / rejected) lives in the fix commits.

**Synthesis note:** 19 findings reviewed; all 19 are genuine and distinct — no exact duplicates (the two model-download findings, the four android.provider findings, and the two atomic-write persistence findings are separate bugs with different triggers, not dedup candidates), so 0 dropped as false positives. Ranking follows the rubric: top tier is anything that feeds unverified bytes to the native GGUF parser, executes a wrong device action, or bypasses a safety/auth gate, ordered within by severity × blast-radius; remaining high-severity data/secret-integrity bugs next; then mediums; then lows. Two honest recalibrations: (1) metrics.service.ts:104 downgraded high→medium — it is a real unserialized read-modify-write race, but the lost content is habit telemetry with bounded per-race loss, not user content, so its blast is materially smaller than the note-truncation bug it was likened to; (2) modelIntegrity.ts:67 keeps its medium base severity but is ranked at #5 (above several highs) because it hands truncated bytes straight to the native GGUF parser — the rubric's top-priority blast surface. One placement note: agent.service.ts:446 is genuinely high (a persistent device error escapes the loop as an unhandled rejection with no terminal event) but is ranked mid (#13) because it neither performs a wrong action, bypasses a gate, nor loses persisted data — its blast is a single aborted mission plus a possible process-level unhandled rejection. The two GGUF findings (#1, #5) and the auth/fence bypasses (#3, #4) are the merge blockers; the three lows (#17–#19) are audit-completeness / resource-leak / cosmetic and can ship as follow-ups.

## Confirmed findings (19)

| # | Sev | Subsystem | Location | Title |
|---|-----|-----------|----------|-------|
| 1 | HIGH | model-download | `src/services/llm.service.ts:144` | Partial, in-flight model download is loadable — native GGUF parser reads a file that is still being written |
| 2 | HIGH | providers | `src/services/providers/android.provider.ts:185` | Literal "%s" in typed text is silently converted to a space — agent types corrupted text on the device |
| 3 | HIGH | network-auth | `src/app.ts:119` | HEAD requests bypass the auth gate on token-protected read routes |
| 4 | HIGH | agent-loop | `src/services/agent/uiVerifier.ts:164` | Raw on-screen element text leaks into the "trusted" action-history channel, bypassing the untrusted-data fence |
| 5 | MEDIUM | model-download | `src/services/modelIntegrity.ts:67` | Magic-header-only integrity check accepts a truncated download — torn bytes fed to the GGUF parser |
| 6 | HIGH | persistence | `src/services/memory.service.ts:312` | saveNote() writes directly to the live file instead of atomicWriteFile, truncating notes on crash |
| 7 | HIGH | capability-safety | `src/services/capability/dashboardTasks.ts:131` | undoLast() unconditionally overwrites lastAgent, orphaning a prior mutating run's persisted undo journal |
| 8 | HIGH | capability-safety | `src/services/capability/capability.ts:118` | Audit ledger never redacts the run's goal field — user secrets persist in every ledger row |
| 9 | MEDIUM | providers | `src/services/providers/android.provider.ts:209` | pressKey() silently sends ENTER for any unrecognized key — can submit forms the agent never meant to submit |
| 10 | MEDIUM | providers | `src/services/providers/android.provider.ts:93` | Screen dimensions are cached forever — scroll() swipes to the wrong place after rotation or a transient query failure |
| 11 | MEDIUM | capability-safety | `src/services/capability/safety.ts:38` | Blocklist multi-word phrases bypassed by true zero-separator concatenation |
| 12 | MEDIUM | capability-safety | `src/services/capability/capabilityAgent.ts:158` | Zero-action anti-lying guard counts attempted capability calls, not successful ones — refusals credited as progress and poison SkillMemory |
| 13 | HIGH | agent-loop | `src/services/agent.service.ts:446` | First per-step UI observation is not wrapped in try/catch — a transient device error silently kills the mission with no terminal event |
| 14 | MEDIUM | persistence | `src/services/metrics.service.ts:104` | Unguarded read-modify-write race on habits.ndjson can silently drop or corrupt records |
| 15 | MEDIUM | agent-loop | `src/services/agent/uiVerifier.ts:35` | Hard-stop (kill switch) cannot interrupt in-flight device I/O — only the LLM decode is abortable |
| 16 | MEDIUM | agent-loop | `src/services/agent.service.ts:480` | Step screenshot leaks to disk on the manual-override and stop-while-paused code paths |
| 17 | LOW | capability-safety | `src/services/capability/runner.ts:176` | executePlan() preview failures are never written to the audit ledger |
| 18 | LOW | providers | `src/services/providers/android.provider.ts:123` | On-device dump/screenshot temp files leak when the adb pull step fails after a successful dump |
| 19 | LOW | model-download | `src/services/modelDownloadPlan.ts:71` | Resume progress can exceed 100% when a 206 response omits Content-Length |

## Detail

### #1 [HIGH] Partial, in-flight model download is loadable — native GGUF parser reads a file that is still being written
- **Location:** `src/services/llm.service.ts:144` (model-download)
- **Failure scenario:** MODEL_MISSING autotriggers downloadModel(), which fs.createWriteStream(dest) opens the FINAL path (modelPath(entry.id)); fs.existsSync(dest) is true from byte 0. A concurrent generalChat()/generateAction() — or a user switchModel(sameId) — calls getModelAndContext(), which selects that exact file purely via fs.existsSync and calls model.loadModel({modelPath: dest}) on a file the write stream is simultaneously appending to. isDownloading is never consulted on any load/select/switch path. Native GGUF loader parses torn/partial bytes → crash or undefined behavior in the native layer.
- **Proposed fix:** Download to `dest + '.part'` and fs.renameSync to the real dest only after verifyModelIntegrity succeeds, so fs.existsSync(dest) is never true for an in-progress/unverified file. Second layer: track the in-flight model id (not just the isDownloading boolean) and have selectBestModel/selectPinnedOrBestModel/switchModel skip or reject that id while it is downloading.

### #2 [HIGH] Literal "%s" in typed text is silently converted to a space — agent types corrupted text on the device
- **Location:** `src/services/providers/android.provider.ts:185` (providers)
- **Failure scenario:** type("increase%special"): the escape regex turns '%' into '\%' but leaves the following 's' (not in the char class) untouched. spawn('adb', args) has no shell, so `\%s` reaches the device shell, which strips the single backslash → `input text` receives "increase%special" → the tool's own %s→space convention fires on the "%s" substring → device renders "increase pecial". Bit-for-bit indistinguishable from an intended space, so the agent enters wrong text into a field it controls.
- **Proposed fix:** A single backslash cannot protect '%' — the device shell consumes one escape level and `input text`'s %s→space substitution is escape-unaware. Detect any literal '%' immediately followed by 's' in the ORIGINAL text and split the call so the two chars never share the argument input scans (flush pending text, send 's' via a separate input/keyevent call, then resume), or replace the `input text` %s convention with a base64 broadcast-intent typing path (ADB Keyboard) that does not reinterpret payload substrings.

### #3 [HIGH] HEAD requests bypass the auth gate on token-protected read routes
- **Location:** `src/app.ts:119` (network-auth)
- **Failure scenario:** `curl -I http://localhost/api/notes/<file>.md` with no token. requiresAuth() only requires the token for `req.method === 'GET'` on PROTECTED_READ_PREFIXES, and HEAD is not in MUTATING_METHODS, so the middleware calls next() unauthenticated. Express 5's router falls HEAD back to the GET handler (route.js: `if (method==='head' && !this.methods.head) method='get'`), so memoryService.listNotes() runs in full and res.json() computes a real Content-Length; the body is suppressed for HEAD but the computed headers (presence/exact size of a note or whether /api/sessions has entries) leak to an unauthenticated local process, and any GET-handler side effects execute.
- **Proposed fix:** Require auth for HEAD as well: change line 119 to `if ((req.method === 'GET' || req.method === 'HEAD') && PROTECTED_READ_PREFIXES.some(...))` (equivalently `['GET','HEAD'].includes(req.method)`).

### #4 [HIGH] Raw on-screen element text leaks into the "trusted" action-history channel, bypassing the untrusted-data fence
- **Location:** `src/services/agent/uiVerifier.ts:164` (agent-loop)
- **Failure scenario:** A malicious app renders a button whose label embeds injection text. uiVerifier.verifyAction() interpolates preNode.text/className verbatim into its return string; agent.service.ts:619 pushes that unmodified into actionHistory; promptBuilder.ts builds historyText and inserts it under the section it labels to the model as 'Recent Actions (trusted agent history)' WITHOUT calling wrapUntrustedData — unlike every other external block (uiState, vision, attachments, corrections, goal, pastMemory) which are all fenced. Attacker-controlled screen text thus reaches the model inside a section presented as trusted, with none of the fence-marker stripping the analogous pastMemory path was deliberately given.
- **Proposed fix:** In promptBuilder.ts wrap the history block via wrapUntrustedData, e.g. `wrapUntrustedData('RECENT_ACTIONS', actionHistory.slice(-5).join('\n'))`, instead of the raw historyText, so screen-derived text gets the same fence-stripping and 'passive observation only' framing as every other untrusted source; additionally sanitize preNode.text/className in verifyAction() before interpolation.

### #5 [MEDIUM] Magic-header-only integrity check accepts a truncated download — torn bytes fed to the GGUF parser
- **Location:** `src/services/modelIntegrity.ts:67` (model-download)
- **Failure scenario:** A multi-GB download with no pinned sha256 is killed after >100MB is written (OOM kill, force-quit, app update). On next launch, downloadModel's 'pre-existing file > 100MB' fast path (llm.service.ts:983-999) calls verifyModelIntegrity, which — with expectedSha256 falsy — only checks hasGGUFMagic on the first 4 bytes and never compares file size to the expected total. The intact header passes, the fast path emits progress:100 and returns, and the partial file is handed to the native GGUF parser as complete.
- **Proposed fix:** Do not infer completeness from `size > 100_000_000`. Persist the expected total size in metaPath whenever known (Content-Length/catalog); when no sha256 is pinned, compare fs.statSync(dest).size against that expected total before accepting a pre-existing file, and fall through to resume/re-download on mismatch — in addition to the magic-header check. (Base severity medium; ranked here because it feeds unverified bytes to the native parser, the rubric's top blast surface.)

### #6 [HIGH] saveNote() writes directly to the live file instead of atomicWriteFile, truncating notes on crash
- **Location:** `src/services/memory.service.ts:312` (persistence)
- **Failure scenario:** Updating an existing note (sanitizeNoteTitle is deterministic, so same notePath). `fs.writeFile(notePath, header + trimmedContent, 'utf-8')` opens with the default O_TRUNC flag; a crash / OOM / power-loss / ENOSPC between truncate and write-completion leaves the file empty or truncated, permanently destroying the prior note content. withWriteLock only serializes in-process writers — it gives zero crash protection. Every other store in this file already routes through atomicWriteFile.
- **Proposed fix:** Replace `await fs.writeFile(notePath, header + trimmedContent, 'utf-8');` with `await atomicWriteFile(notePath, header + trimmedContent);` (atomicWriteFile is already imported), matching how memoryPath and correctionsPath are persisted.

### #7 [HIGH] undoLast() unconditionally overwrites lastAgent, orphaning a prior mutating run's persisted undo journal
- **Location:** `src/services/capability/dashboardTasks.ts:131` (capability-safety)
- **Failure scenario:** Task A mutates: undoable.length>0 so journal.save(actionsA) runs and lastAgent=agentA. Task B runs with zero mutations: journal.save is skipped (journal still holds actionsA) but line 131 still executes lastAgent=agentB, discarding the only reference to agentA's RunSession. undoLast() then calls agentB.undoAll() → returns 'Nothing to undo from this task.' (empty done array) and unconditionally runs journal.clear(), wiping A's still-valid, still-unreversed persisted actions. The user sees a truthful-looking 'nothing to undo' while the durable cross-session undo record for A's real mutations is permanently destroyed.
- **Proposed fix:** Move `this.lastAgent = agent;` inside the `if (undoable.length > 0) { ... }` block so lastAgent (and the persisted journal it clears) always tracks the most recent run that actually produced something to undo, keeping the two in lockstep.

### #8 [HIGH] Audit ledger never redacts the run's goal field — user secrets persist in every ledger row
- **Location:** `src/services/capability/capability.ts:118` (capability-safety)
- **Failure scenario:** setRunGoal("log into billing, password: hunter2") is taken from the raw user task string; log() stamps `goal: this.runGoal` onto every entry for the run, including plain reads. InMemoryAuditLedger.append() spreads entry and only redacts+truncates input and outcome — goal passes through completely untouched, and the blocklist gate never inspects the run-level goal. The secret rides untouched into every ledger row for the whole run, directly contradicting the file's 'the ledger is a record, never a place a leaked secret lives' invariant.
- **Proposed fix:** In InMemoryAuditLedger.append() redact+truncate goal exactly like input/outcome: `goal: entry.goal ? redactSecrets(entry.goal).slice(0, 200) : entry.goal`.

### #9 [MEDIUM] pressKey() silently sends ENTER for any unrecognized key — can submit forms the agent never meant to submit
- **Location:** `src/services/providers/android.provider.ts:209` (providers)
- **Failure scenario:** `let code = '66'` is the default and only enter/back/home override it. pressKey('escape') to dismiss a picker, or pressKey('tab') to move focus, falls through with code still '66' → `input keyevent 66` (KEYCODE_ENTER) with no error or no-op. On many forms Enter triggers submission — a mutating state change the agent never requested and that is untraceable without reading this source.
- **Proposed fix:** Add explicit mappings for the keys an agent commonly requests (tab→61, delete/backspace→67, escape→111, space→62, arrows→19-22), and for a genuinely unrecognized key name reject the promise or log a clear warning and skip sending a keyevent, rather than silently substituting Enter.

### #10 [MEDIUM] Screen dimensions are cached forever — scroll() swipes to the wrong place after rotation or a transient query failure
- **Location:** `src/services/providers/android.provider.ts:93` (providers)
- **Failure scenario:** screenDimsQueried is set true (line 97) BEFORE the `wm size` try/catch and is never reset. (1) If `wm size` throws (ADB_TIMEOUT on a cold device), the hardcoded 1080x2400 fallback is cached permanently and never re-queried even after the device reports a different real resolution. (2) Once real dims are cached, an in-session portrait↔landscape rotation is never invalidated, so scroll()'s startX/startY/endY math keeps using stale values and swipes to the wrong on-screen location.
- **Proposed fix:** Only set screenDimsQueried=true after a successful parse (move it inside the `if (match)` block, or track 'succeeded' separately from 'attempted') so a failed query is retried next call instead of locking in the fallback; add an explicit invalidate/refresh hook or short TTL so a mid-session rotation is re-queried rather than cached for the instance lifetime.

### #11 [MEDIUM] Blocklist multi-word phrases bypassed by true zero-separator concatenation
- **Location:** `src/services/capability/safety.ts:38` (capability-safety)
- **Failure scenario:** The tokenizer splits on `_`/`-`, so underscore/hyphen inputs still match single-word entries (NOT a bypass — the candidate's framing was wrong there). But a true no-separator smash — 'placeorder now', 'sendmoney', 'confirmpayment' — becomes a single merged token that matches neither the multi-word literal-substring check (no space present) nor any single-word entry (component words for place/send order/money aren't independently listed, and 'purchase'/'payment' get absorbed into a larger token). matchedBlockedKeyword returns undefined and a blocked phrase slips through. Narrow: real resourceIds are camelCase/snake_case (already handled); most likely in prose typos or deliberately obfuscated injected text.
- **Proposed fix:** Add a second multi-word check against a fully-squashed string alongside the existing literal-substring check: `const squashed = lower.replace(/[^\p{L}\p{N}]+/gu, ''); if (squashed.includes(kw.replace(/\s+/g, ''))) return kw;`.

### #12 [MEDIUM] Zero-action anti-lying guard counts attempted capability calls, not successful ones — refusals credited as progress and poison SkillMemory
- **Location:** `src/services/capability/capabilityAgent.ts:158` (capability-safety)
- **Failure scenario:** Model calls {"tool":"fs.trash","input":"delete customer_ssn.csv"}. `cap = byName.get('fs.trash')` resolves truthy, so usedTools.push/usedSteps.push run unconditionally — even though runner.execute() refuses via the blocklist ('delete') and returns a 'Refused:' string that is never inspected. Model answers {"answer":"Done, deleted the file."}; the guard checks only usedTools.length===0, now false, so it never fires and the false 'Done' is returned with halt:'answered'. Worse, usedSteps.length>0 records the refused sequence into SkillMemory as a 'proven' sequence. Same unconditional push in the plan branch.
- **Proposed fix:** Only credit a step when the observation reflects an actual attempt/execution, not a refusal — have runner.execute/executePlan return a structured `{ text, performed }` (or a stable set of refusal-prefix constants) and gate the usedTools/usedSteps push on `performed`, so blocklist/consent/approval/bulk/error refusals never count as progress or feed SkillMemory.

### #13 [HIGH] First per-step UI observation is not wrapped in try/catch — a transient device error silently kills the mission with no terminal event
- **Location:** `src/services/agent.service.ts:446` (agent-loop)
- **Failure scenario:** `const state = await this.uiVerifier.waitForIdle(emitter)` sits bare in the while-loop body. waitForIdle throws after 3 cumulative getScreenContext() failures within one call (the retries counter is never reset on an intervening success). The throw propagates out of _runAgentLoop into runAgentLoop's try/finally, which has no catch — so no emitter.emit('error') / emit('done') ever fires and the rejection re-throws to the caller (possible top-level unhandled rejection / hung UI). The identical call at line 615 is inside the try at 535 and IS caught and retried — a genuine asymmetry.
- **Proposed fix:** Wrap the line-446 waitForIdle in the same try/catch used at 535-640 (or extend that outer try to cover the whole step body from 446 onward), so a persistent device error emits 'error'+'done' or enters the existing backoff-and-retry path instead of escaping the loop. (Severity high for the possible process-level unhandled rejection, but ranked here because it performs no wrong action, bypasses no gate, and loses no persisted data.)

### #14 [MEDIUM] Unguarded read-modify-write race on habits.ndjson can silently drop or corrupt records
- **Location:** `src/services/metrics.service.ts:104` (persistence)
- **Failure scenario:** appendHabitLog is a bare fs.appendFile with no lock. getHabits() reads the whole file, snapshots 'kept = last 1000' when lines>2000, and fires atomicWriteFile(...).catch(()=>{}) WITHOUT awaiting. If a concurrent append lands after the snapshot but the compaction rename completes after the append (independent libuv async chains, no ordering guarantee), the rename replaces the inode with the stale pre-append snapshot → the appended entry is permanently lost with no error surfaced. Also, two same-process getHabits() compactions share a pid-only tmp name (atomicWrite.ts:13), so the second rename() hits ENOENT and is swallowed. Downgraded high→medium: the lost content is habit telemetry with bounded per-race loss, not user content.
- **Proposed fix:** Serialize ALL writes to habitsNdjsonPath (both appendHabitLog and getHabits' compaction) through one promise-chain mutex, mirroring the writeChain already used for telemetryPath in this class (or memory.service withWriteLock). Await the atomicWriteFile in getHabits so failures are observable, and make atomicWriteFile's tmp name collision-proof within a process (add a monotonic counter or crypto.randomUUID() suffix alongside pid).

### #15 [MEDIUM] Hard-stop (kill switch) cannot interrupt in-flight device I/O — only the LLM decode is abortable
- **Location:** `src/services/agent/uiVerifier.ts:35` (agent-loop)
- **Failure scenario:** stop() only calls _abortController.abort(), whose signal is passed exclusively to generateAction(). waitForIdle(emitter) and ActionExecutor.execute(actionObj, elements, emitter) take no AbortSignal and never check any stop flag; stopped() is only checked between steps and around the pause-wait, not while awaiting waitForIdle or execute. If deviceProvider.getScreenContext()/click/type/scroll/pressKey hangs, stop() cannot short-circuit it — the loop only exits once the in-flight call settles. (The Q-523 comments scope the guarantee to the decode + loop/pause-wait, so this is an accurately-scoped but real functional gap, not a contradicted doc.)
- **Proposed fix:** Thread the AbortSignal into waitForIdle(signal) and execute(..., signal); check signal.aborted at each poll iteration in waitForIdle's while loop, and race the device-provider calls against a signal-triggered rejection (Promise.race) so stop() can interrupt an in-flight device call, not just the LLM decode.

### #16 [MEDIUM] Step screenshot leaks to disk on the manual-override and stop-while-paused code paths
- **Location:** `src/services/agent.service.ts:480` (agent-loop)
- **Failure scenario:** state.screenshotPath is only unlinked in the finally at 521-528, attached to the generateAction try at 496-520. The stop-while-paused break at 468 and the manual-override continue at 480 both exit after state was fetched (446) but before that try runs, so the current iteration's 2-5MB PNG (which uiVerifier deliberately leaves for the caller to clean up) is never deleted. Repeated overrides accumulate leaked screen captures — a privacy-sensitive on-disk leak of the user's screen.
- **Proposed fix:** Explicitly unlink state.screenshotPath immediately before the continue at 480 and before the break at 468, or restructure to a per-iteration try/finally that unconditionally cleans up the current state's screenshot on every exit path.

### #17 [LOW] executePlan() preview failures are never written to the audit ledger
- **Location:** `src/services/capability/runner.ts:176` (capability-safety)
- **Failure scenario:** In execute() a capability.plan(input) throw is ledgered via this.log(..., 'error', ...). In executePlan()'s pre-flight loop the analogous catch only returns a message to the caller — this.log() is never called, unlike the blocklist-hit (166) and needsConsent (170) branches in the same loop. A plan whose 2nd step's plan() throws aborts with a message but leaves zero trace (including earlier successfully-previewed steps) in ledger.entries(), contradicting the ledger's 'every invocation, incl. refusals' contract.
- **Proposed fix:** In executePlan()'s pre-flight catch block call `this.log(item.capability, item.input, 'error', `preview failed: ${String(e)}`);` before returning, mirroring the single-action execute() path.

### #18 [LOW] On-device dump/screenshot temp files leak when the adb pull step fails after a successful dump
- **Location:** `src/services/providers/android.provider.ts:123` (providers)
- **Failure scenario:** getUiHierarchyXml runs dump→pull→`rm -f devXml` sequentially; if the dump succeeds but the pull rejects (ADB_TIMEOUT, which spawnAdb explicitly models), the await on the rejected pull throws straight to the outer `catch { return "" }`, skipping the rm line so devXml is never deleted. Same shape in getScreenContext (cleanup chained via .then after pull). waitForUiIdle calls getUiHierarchyXml up to 10× per idle-wait with fresh UUIDs, so repeated transient pull failures accumulate orphaned on-device files.
- **Proposed fix:** Wrap the dump+pull steps in a try/finally (or attach the `rm -f ... .catch(()=>{})` as an always-run .finally step) so the on-device temp file is removed regardless of whether the pull succeeds, in both getUiHierarchyXml and getScreenContext.

### #19 [LOW] Resume progress can exceed 100% when a 206 response omits Content-Length
- **Location:** `src/services/modelDownloadPlan.ts:71` (model-download)
- **Failure scenario:** llm.service.ts:1085 defaults contentLength to 0 when the header is absent; modelDownloadPlan.ts:71's resume branch then sets totalBytes = partialBytes + 0. In the download loop receivedBytes starts at partialBytes and grows per chunk while totalBytes stays fixed, so progress = round(receivedBytes/totalBytes*100) exceeds 100% almost immediately and climbs all session. Reproducible whenever a CDN/proxy answers a Range request with 206 and chunked encoding (no Content-Length). Purely cosmetic — write/append offset logic is unaffected.
- **Proposed fix:** In planDownloadWrite's resume branch use `totalBytes: contentLength > 0 ? partialBytes + contentLength : 0` so the loop's existing `if (totalBytes > 0)` guard suppresses percentage display instead of computing a value that can exceed 100%.

---

## Disposition (2026-07-11) — all 19 triaged

**Fixed + tested (17):**
- #1 partial-GGUF load → staging `.part` + rename-after-verify (`llm.service`); #5 size-gate in
  `verifyModelIntegrity`; #19 206-resume-no-CL progress. #3 HEAD auth gate (`app.ts`). #8 ledger
  redacts `goal`. #6 `saveNote` atomic. #4 action-history fenced as untrusted (`promptBuilder`) +
  label cap (`uiVerifier`). #13 graceful observation-error termination. #16 screenshot cleanup on
  override/stop paths. #2 literal-`%s` split (`splitLiteralPercentS`). #9 `pressKey` rejects unknown
  keys. #10 dims TTL + cache-on-success-only. #7 `lastAgent` guarded on undoable. #12 `runner.lastExecuted`
  gates progress/skill-memory credit. #14 habits write-chain + re-read compaction. #17 plan-preview
  failure ledgered. #18 device-rm `.finally` + local-temp cleanup on read failure.

**Downgraded during independent re-verification:**
- #13 HIGH→medium: the synth claimed an "unhandled rejection", but all three `runAgentLoop` callers
  already catch (WS/CLI/voice). The real (smaller) gap — bypassed terminal events + a scary generic
  message on a transient device error — is what was fixed.

**Deferred, with rationale (2):**
- #11 (blocklist multi-word phrase bypassed by zero-separator concatenation, e.g. "sendmoney" evading
  'send money'): REAL but the blocklist matching is parity-pinned across three platforms
  (`safety.ts` + Swift + Kotlin, `check_safety_parity.py`). A correct fix must land in all three twins
  together (and add a shared parity vector), which needs the Swift/Kotlin build+test loop — not
  safely doable from this machine. Tracked for a 3-platform pass. Mitigation today: it is
  defense-in-depth UNDER consent + per-run approval + ledger, and single-word dangerous tokens
  ('pay','buy','delete','transfer','withdraw'…) still match.
- #15 (hard-stop can't interrupt in-flight device I/O — only the LLM decode is abortable): REAL and
  architectural. `spawnAdb`/native input calls run to completion; the kill switch is honored BETWEEN
  steps (the loop checks `signal.aborted` each iteration), so at most one in-flight action completes
  after Stop. Making a single adb/native call itself cancellable is a provider-level design change
  (process-kill semantics per platform) — scoped as its own task, not a hotfix.
