# Adversarial verification — 2026-07-06

Dual-skeptic verification of this session's six fix-clusters, plus a fresh bug-hunt over
three never-audited native surfaces (iOS SwiftUI, Android Compose, JNI bridge).

Raw data: [`2026-07-06-adversarial-verification.raw.json`](./2026-07-06-adversarial-verification.raw.json)

---

## Verdict summary

| Fix cluster | Files touched | Verdict |
|---|---|---|
| Q-530 — never persist passphrase as plaintext | `ui/src/App.tsx`, `ui/src/components/SettingsArea.tsx`, PrivacyLock | **DEFECT** (P2 stale-closure lost-update; security goal itself holds) |
| Q-596 — WS connect adopts active session | `src/websocket/index.ts` | **DEFECT** (P1 unguarded `new_session` reintroduces wrong-session write) |
| Q-597 — activate session flush-before-switch | `src/websocket/index.ts`, `src/services/session.service.ts` | **DEFECT** (P1 unguarded `activate_session` race — CONFIRMED by 2nd skeptic) |
| Q-527/528/529 — res.ok gating on catalog/model/note actions | `ui/src/components/SettingsArea.tsx`, `ui/src/.../Docs.tsx` | **DEFECT** (P2 error-slot clobber; P3 stale error; headline fixes sound) |
| Q-637 — remove dead LLM-fallback intent classifier | `intentClassifier.ts`, `agent.service.ts` | **SOLID** |
| Q-524/534 — sandbox renderer + real tray icon | `src/electron/main.ts` | **DEFECT** (P1 tray-icon path off by one dir; Q-534 effectively unfixed) |

One cluster SOLID, five carry defects. Only Q-524/534, Q-596, and Q-597 leave a headline
fix broken or reintroduced; Q-530 and Q-527/528/529 achieve their stated goal but ship a
lower-severity regression alongside.

---

## Surviving defects

Only one defect was run through the second skeptic, and it was **CONFIRMED (`refuted: false`)** — a real, un-refuted defect.

### P1 — `src/websocket/index.ts:451` — Q-597 `activate_session` wrong-session write (CONFIRMED)

**What's wrong.** The `activate_session` WS handler is synchronous and has no guard against
an in-flight chat generation. The `chat` handler awaits `generalChat()` at line 297 and only
persists the turn via `addMessage()` at lines 335-336 *after* the await resolves, without ever
pinning the session id it started with. Node's `ws.on('message', async …)` callbacks interleave
across await points, and the single-flight guard at lines 273-276 only rejects a concurrent
`chat`/`start` — it does not cover `activate_session`. So an `activate_session` dispatched
mid-generation flushes the outgoing session (without the not-yet-persisted turn) and makes the
target current before the parked chat handler resumes and writes into the now-current session.

**Failure scenario.** User is in session A and sends chat message X. The server parks at
`await generalChat(…)` streaming tokens. Mid-stream the user clicks conversation B in the
sidebar; the client's `loadSession(B)` (`ui/src/hooks/useAgentSocket.ts:421-441`) sends
`{type:'activate_session', sessionId:B}` with **no `status==='running'` guard** (unlike
`sendGoal`). Between token callbacks the event loop dispatches it: `activateSession(B)` flushes
A *without* X, sets currentSession=B. Generation finishes; lines 335-336 run
`addMessage('user','X')` / `addMessage('assistant', reply)` against B. Result: A loses X entirely
and B gains A's whole turn — exactly the wrong-session write Q-597 set out to eliminate. The new
`tests/session.service.test.ts` test drives `activateSession()` only in the synchronous,
non-interleaved path, so it passes while the race survives (false confidence, not a refutation).

The second skeptic attempted four refutations (single-flight guard, an ordering guarantee, a
pre-await session pin, a client-side disable-during-generation) and none exist in the read code.

---

## Fresh bugs (never-audited surfaces)

Ranked by severity, then confidence (HIGH first). These come from the bug-hunt, not the verify
pass, so they carry no second-skeptic confirm — treat confidence as stated.

### P1 · HIGH — `apple/QuenderinKit/Sources/QuenderinKit/SettingsView.swift:447` (iOS)
`.onDelete` in `downloadedModelsSection` deletes by index into `installedModels` while
`deleteModel(_:)` mutates that same array mid-loop (via `reloadModelStorage()` reassigning it).
`offsets.forEach { deleteModel(installedModels[$0]) }` re-reads the shrinking array each
iteration. The codebase's own `ConversationHistoryView.swift:132-137` snapshots stable ids
before mutating — this view does not.
**Failure:** multi-row delete of 3+ models with `IndexSet {1,2}` → iteration 2 indexes a
now-2-element array → Swift index-out-of-range crash; `{0,1}` deletes the wrong model instead.

### P1 · HIGH — `android/app/src/main/kotlin/ai/quenderin/app/ui/AgentScreen.kt:74` (Android)
`AgentSession.onChange` writes Compose state (steps/answer/running/haltReason) directly with no
marshaling onto the main dispatcher, while `session.run(g)` runs on `Dispatchers.IO` (line 195)
and `onChange()` fires synchronously on the calling thread. Every emit mutates Compose snapshot
state from the IO thread — the exact twin of the Q-228 bug `ChatScreen` already fixed
(`ChatScreen.kt:118-124`); `AgentScreen` never got the fix.
**Failure:** during a run, off-main-thread `MutableState` writes violate the snapshot threading
model — missed/torn recompositions, or a crash in strict/debug builds, so steps and the final
answer can fail to render intermittently under real streaming.

### P1 · MED — `apple/QuenderinKit/Sources/QuenderinKit/ModelsLibraryView.swift:576` (iOS)
In `download(_:)`, when `DownloadCoordinator.claim(filename)` fails (file already being written
by another downloader), the task sets `states[entry.id] = .downloading(0)`, clears
`tasks[entry.id] = nil`, and returns — no task and no path will ever advance that state.
`downloadAllMissing()` (line 552) polls `while case .downloading` with a 300ms sleep, so it
never exits.
**Failure:** "Download the complete library" while the onboarding installer is fetching a
same-filename model → that entry busy-waits forever, permanently blocking the sequential queue
so no remaining model in the batch starts.

### P2 · MED — `android/.../ui/ChatScreen.kt:129` (Android)
Auto-scroll `LaunchedEffect` keys on `(messages.size, busy)`. A streaming reply replaces the
last message token-by-token; the list *size* never changes, so the effect never re-fires and
the growing bubble scrolls off the bottom. Should key on transcript content/length, not element
count.
**Failure:** multi-paragraph streamed reply falls below the fold; user must scroll manually to
watch it generate.

### P2 · MED — `android/.../ui/SettingsScreen.kt:178` (Android)
Model delete runs blocking filesystem I/O on the main thread: the Delete `onClick` calls
`ModelManager(...).delete(installed.id)` then `reloadModels()` (dir enumeration + size summing)
directly in the lambda. `reloadModels()` is also called from `LaunchedEffect(model.id)` (line 77)
on the Main dispatcher.
**Failure:** deleting a multi-GB GGUF unlinks the file and re-enumerates the dir on the main
thread — UI freeze, possible ANR on slower storage.

### P2 · MED — `android/jni/llama_jni.cpp:112` (JNI)
In `generate()`, `GetFieldID("cancelRequested")` / `GetMethodID("recommendedThreads")` can
return null leaving a pending exception that is never checked/cleared before the decode loop
(unlike thermalPoll:143 and emit:126). The next JNI call in the token loop with a pending
exception is UB → ART aborts the process.
**Failure:** a release build where R8/ProGuard renames/removes those members (or the signature
drifts) → generation proceeds with an uncleared pending exception → process abort instead of a
streamed reply.

### P3 · MED — `android/.../ui/ChatScreen.kt:130` (Android)
Off-by-one in the auto-scroll target: the LazyColumn always renders a `DayDivider` at index 0
(line 164), so the last valid index is `messages.size + (busy?1:0)`, but the effect scrolls to
`count-1`, one row short. Newest message / typing bubble never fully scrolls into view.

### P3 · MED — `android/jni/llama_jni.cpp:100` (JNI)
`GetMethodID(cls, "onToken", …)` can return null with a pending `NoSuchMethodError`; the code
only guards `if (!on_token)` to pick streaming vs accumulate and never clears the exception,
then continues into the `thiz` block and decode loop with an exception pending → UB.

### P3 · LOW — `android/jni/llama_jni.cpp:69` (JNI)
`make_jstring()` uses `FindClass`/`GetMethodID`/`NewStringUTF("UTF-8")` results in `NewObject`
with no null-checks, and no `ExceptionCheck` after `SetByteArrayRegion`. Under OOM a null
charset (or null `jmethodID`) reaches `NewObject` → UB instead of a clean OOM, defeating
`throw_oom`'s contract.

### P3 · LOW — `android/jni/llama_jni.cpp:54` (JNI)
`tokenize()` assumes the zero-capacity probe `-llama_tokenize(...)` is always non-positive.
A future llama.cpp bump or edge input returning a positive count makes `n` negative; passed to
`std::vector<llama_token>(n)` as `size_t` it requests ~`SIZE_MAX` elements → `bad_alloc`/crash.

---

## Fix next

Ordered — confirmed and HIGH-confidence items only:

1. **Q-597 `activate_session` race (P1, CONFIRMED)** — `src/websocket/index.ts:451`. Guard
   `activate_session` against in-flight generation (defer/reject like Q-275), and/or pin the
   session id at chat-start so `addMessage` writes back to the originating session, and/or gate
   the client `loadSession` on `status!=='running'`. This is the only second-skeptic-confirmed
   defect.
2. **Q-596 unguarded `new_session` (P1)** — `src/websocket/index.ts:443`. Same root cause as #1;
   guard `new_session` on `!isCurrentlyGenerating` and/or capture the session id at chat-start.
   Fix together with #1.
3. **Q-524/534 tray icon (P1)** — `src/electron/main.ts:91`. Add the third `..`:
   `path.join(__dirname,'..','..','..','public','favicon.png')`. Q-534 is otherwise unfixed
   despite the commit/journal claiming success.
4. **iOS multi-row model delete (P1 · HIGH)** — `SettingsView.swift:447`. Snapshot stable ids
   before deleting, mirroring `ConversationHistoryView.swift:132-137`.
5. **Android AgentScreen off-main-thread state writes (P1 · HIGH)** — `AgentScreen.kt:74`.
   Marshal `AgentSession.onChange` onto `Dispatchers.Main.immediate`, mirroring the Q-228
   `ChatScreen` fix.
6. **Q-530 migration stale-closure lost-update (P2)** — `ui/src/App.tsx:419`. Persist via a
   functional `updateSettings(prev => ({...prev, privacyPassphrase: h}))` so a concurrent
   settings change during the async hash window isn't reverted. Lower priority: security goal
   holds, one-time-per-upgrade only.

Lower-severity items (Q-527/528/529 error-slot clobber, iOS stuck download-queue, Android
auto-scroll, JNI exception-clearing) are logged in the raw JSON for a follow-up pass.
