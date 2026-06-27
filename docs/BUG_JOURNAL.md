# Bug Journal

Cheap-to-write, cheap-to-read, expensive-to-skip. `grep -i <symptom>` this before debugging.

## Patterns to scan for FIRST

- **Falsy-zero / falsy-empty guards.** `if (!id)` / `if (!title)` wrongly fire on the valid
  value `0` or on a string that sanitizes to `""`. Use explicit `=== undefined || === null`,
  and validate the *sanitized* value, not the raw one. (H8, M14)
- **Off-by-N "caps".** `if (len > N) arr.slice(1)` only ever drops ONE element and pins the
  array at N+1 forever. Use `arr.slice(-(N-1))` before pushing. (M7)
- **In-place array mutation on a parsed/shared array.** `records.reverse()` mutates; copy
  first (`[...records].reverse()`) — becomes a real bug the moment the parse is cached. (M15)
- **`@MainActor` + `await` = reentrancy.** Every `await` yields the actor, so other UI actions run mid-
  method. Two shapes: (a) an array index captured before an await and used after — a concurrent mutation
  (Clear/`reset`, History/`restore` during a streamed reply) makes it out-of-bounds (crash) or points at
  the wrong element; identify the row by a STABLE id, re-look-it-up each await, stop if it's gone. (b) a
  method that can be RE-TRIGGERED before it finishes (install/switch/submit) racing shared state + side
  effects — add a `guard !inFlight` re-entrancy guard. (chat streaming reentrancy; install guard)
- **Advertised-but-unimplemented surface.** A prompt/doc/interface lists capabilities the
  executor/provider doesn't implement (dead `pressKey`, advertised `swipe`). Keep the prompt,
  the type union, and the executor in lockstep. (C8, C9)
- **Device/host shell re-tokenization.** `adb shell input text "$x"` is re-parsed by the
  DEVICE shell — single-argv is NOT enough; escape metacharacters + encode spaces. (H1, M9)
- **`spawn()` / write streams need an `'error'` handler (or it's an uncaught exception).** If a
  `spawn`'d binary is missing (`ENOENT`, e.g. adb / platform-tools) it emits `'error'`, NOT `'close'` —
  unhandled, Node re-throws it as an uncaught exception, and a Promise that only settles on `'close'`
  HANGS until an unrelated timeout (misleading "timed out" for "not installed"). A `fs.createWriteStream`
  that errors mid-write (`ENOSPC` on a tight disk, permission) does the same. Always handle `'error'`;
  for a write loop also unblock the `drain`/`end` waits on `'error'` (else they hang) and `destroy()` the
  stream in a `finally` to free the handle. (adb spawn error handler; download/extract stream handlers)
- **Resume/Range trust.** A `Range:` request can be answered `200` (server ignores it) — reset
  byte counters; verify a `206`'s `Content-Range` start before appending. (H9)
- **Untrusted XML/entities.** Device/network-sourced XML needs `processEntities:false`. (H34)
- **Don't blindly `n_gpu_layers = 999` on Android.** Vulkan driver quality is heterogeneous — Adreno
  (Snapdragon) is proven; Mali/Xclipse can be slower-than-CPU or crash on llama.cpp's compute shaders.
  Gate offload per-SoC (`GpuOffloadPlanner`), default CPU, and remember decode is bandwidth-bound so the
  GPU win is mostly prefill — measure before trusting it. (android gpu offload)
- **WorkManager `Result.failure` is terminal.** A cooperative stop (`isStopped` → constraint loss like
  Wi-Fi off, or a cancel) must return `Result.retry()`, not `failure`, or the work never auto-resumes.
  Catch the cancel exception separately from real errors. (workmanager retry vs failure)
- **Hand-rolled unescaper vs a real JSON parser (twin drift).** One platform parses with a JSON lib,
  its twin hand-extracts string values — the hand-rolled side silently drops `\uXXXX` / `\r` / `\b` /
  `\f` (mangling non-ASCII + emoji, e.g. `café` → `cafu00e9`) while the lib decodes them. Decode
  the FULL JSON escape set on the hand-rolled side; pin it with a cross-platform parity test whose
  INPUT is a literal escape and whose EXPECTED is the decoded char. (agent parser \u)
- **Lenient date parser silently rolls over invalid dates.** Foundation `DateFormatter` turns
  `2026-02-30` into `2026-03-02` (and a non-leap `2026-02-29` → `03-01`) and computes from a date the
  user never typed; `java.time.LocalDate` rejects them. Validate a lenient parse by ROUND-TRIPPING —
  format the parsed date back and reject it if it ≠ the input. (date roll-over)
- **String length/truncation: Swift graphemes vs Kotlin UTF-16 (twin drift).** Swift `String.count`/
  `.prefix` count extended grapheme clusters; Kotlin `length`/`substring` count UTF-16 code units. So a
  truncated title/label cuts at a different point on each platform for emoji/CJK/combining text (and a
  naive Kotlin `substring` can split a surrogate pair → invalid UTF-16). Truncate by **code points** on
  both (`unicodeScalars.prefix` / `offsetByCodePoints`) for parity + safety. (title truncation)
- **ICU vs Java regex `\b`/`\w` (twin drift).** iOS `NSRegularExpression` (ICU) treats accented/Unicode
  letters as word chars in `\b` BY DEFAULT; Android `java.util.regex` is ASCII-only unless you add the
  `(?U)` inline flag. A shared safety/validation regex WILL diverge on non-ASCII text — `\bpin\b` fired
  on `piné`/`épin` on Android but not iOS. Force the same word semantics: `(?U)` on the Java side. (regex \b parity)
- **Bind address + "localhost" logs.** `server.listen(port)` binds all interfaces; the log
  saying `localhost` lies. Bind `127.0.0.1` explicitly. (C1)
- **Docs describing a different product.** Security/feature docs that claim ports, rate limits,
  config files, or providers that don't exist are worse than none — verify against source. (H5)
- **`vitest run` with no `include`** walks vendored/symlinked trees (e.g. a llama.cpp checkout
  under `jni/`). Scope `include` to `tests/`.
- **Test ≠ shipped code.** Tests that re-implement the function under test, or assert
  `>= 0` / `toBeDefined()`, verify nothing. Import the real export; assert the real value.
- **Unverified download → parser.** Bytes streamed from the network to a native parser MUST be
  checked first (magic header always; pinned SHA-256 when known). Verify in the REAL downloader,
  not the orchestrator — the mock writes a placeholder and would fail an orchestrator-level gate.
  Delete a failed file; never resume onto a poisoned partial. (C3)
- **Regex that stops at a delimiter the data also contains.** `ModelEntry\([^)]*\)` truncated at
  the `)` inside a label ("Qwen3 14B (Best Quality)"). Anchor on stable boundaries (`id…urlString`,
  line-end `$`), never on a delimiter that appears inside a field.
- **Hand-synced catalog = one field in 5 places.** A new model field lives in TS + Swift + Kotlin
  source, the generated `shared/model-catalog.json`, AND the generator + parity checker. Use
  `scripts/refresh_model_hashes.py` + `npm run gen:catalog`; `check_catalog_parity.py` guards drift.
- **Hand-mirrored parity SUITES drift like a hand-synced catalog.** Two test files that pin the same
  cross-platform contract ("keep this in lockstep with the Kotlin mirror") WILL drift — Kotlin pinned the
  `\t`/`\n` short-escape decode; Swift's `AgentParityTests` silently didn't. A comment can't enforce a
  bijection. Make the vectors a language-neutral `shared/*.json` with stable `id`s, tag each platform's
  assertion `// parity:<id>`, and let `check_agent_parity.py` (CI) fail on any missing/orphan id. Same
  guardrail shape as `check_catalog_parity.py`. (agent parity coverage)
- **Pinned mirror URLs rot.** A catalog HF URL can 404 (lmstudio-community ships no Q2_K). Verify
  download URLs actually resolve; prefer a mirror that hosts the exact quant. Run
  `npm run check:catalog-urls` (1-byte Range GET per URL) before a release to catch rot before a
  user hits a 404 mid-download.
- **Cached/pre-existing files are still untrusted.** An "already downloaded, skip" fast-path that
  returns without re-verifying re-opens the integrity hole on every launch. Verify the cached
  artifact too; delete + re-fetch on failure. (C3-1)
- **Wrong lookup key silently downgrades a security check.** Resolving a security value (sha256) by
  the wrong identifier (filename vs catalog id) returns nil → silent fallback to the weaker check,
  no error. Resolve by the SAME key the catalog uses; add a regression test. (C3-2)
- **PEP 604 `X | None` is eager in a runtime assignment.** Fine in annotations under
  `from __future__ import annotations`, but `Alias = dict[..., X | None]` evaluates `|` now and dies
  on Python <3.10. Use `Optional[X]`.
- **WorkManager foreground service needs an explicit manifest `<service>`.** WorkManager does NOT
  merge `android:foregroundServiceType` into the merged manifest, so a runtime `setForeground(…DATA_SYNC)`
  throws `MissingForegroundServiceTypeException` on API 34+. Declare `<service
  android:name="androidx.work.impl.foreground.SystemForegroundService" android:foregroundServiceType=…
  tools:node="merge"/>` even though you never author the service class yourself.
- **Native handle lifecycle: free-before-reassign AND free-before-drop/null.** Re-`load()` that overwrites a
  `llama_model*`/`llama_context*` without freeing leaks multi-GB until process exit (C1); a free on one
  thread during a native call on another is a use-after-free — serialize load/unload/complete (C2). Same
  trap in JS: a native-backed handle (node-llama-cpp `LlamaModel`/`LlamaContext`) must be `.dispose()`d
  before you set its field to `null` — GC won't promptly reclaim native memory, so an "unload to free RAM"
  that only nulls frees NOTHING, and a partially-built load (model loaded, context creation then failed)
  leaks the model unless the catch disposes it. Grep every `Instance = null` / handle-drop for a missing
  `.dispose()`. (llm.service unloadModel + init-fail leak)
- **Recursive-descent parser on untrusted input needs a depth cap.** A Swift stack overflow is NOT a
  catchable `Error` (deep nesting hard-crashes); the JVM raises a catchable `StackOverflowError` → silent
  crash-vs-graceful parity break. Thread a depth limit through both. (C4)
- **Pooled resources must be disposed on rotation.** A KV-cache sequence slot (fixed-N pool) leaks if the
  holder is replaced/nulled without `dispose()` → "No sequences left" after the first rotation. (KV-cache)
- **JNI: clear pending exceptions before the next JNI call; null-check `Get`/`NewStringUTF`.** A callback
  that throws leaves a pending exception; the next JNI call is UB → ART aborts the process. (C3, H4, H5)
- **A "running"/"busy" flag must reset in `finally`.** Resetting only on the happy path leaves it stuck
  `true` after any throw → the feature is silently dead for the whole process. Wrap the body; reset in
  `finally`. (H7)
- **Poll-until-stable loops need a hard iteration cap + `finally` cleanup.** A "wait for idle" loop with
  only a per-error retry cap spins forever on an animating UI and never reaches post-loop cleanup. Cap the
  polls; clean up in `finally`. (H8)
- **Origin checks: compare parsed origins, not `startsWith`.** `url.startsWith("http://localhost:3000")`
  passes for `http://localhost:3000.attacker.com`; and `will-navigate` misses server 3xx redirects — also
  handle `will-redirect`. (H11, H12)
- **View-model publishes terminal state the view never renders.** A bindable VM exposes a non-success
  terminal field (`haltReason`, `error`, empty-result) but the view only renders the happy path → a
  silent dead-end (steps trail off, no explanation). Render EVERY terminal state; put the human-readable
  copy in the shared core so both platforms stay in parity and it's unit-testable. (agent halt-reason)
- **A safety/validation gate that covers only ONE producer of the gated data.** `SafetyBlocklist` gated
  agent tool calls + the agent's final answer, but plain chat output bypassed it entirely — same data
  type (model output), different code path, no gate. When you add a gate, audit EVERY path that emits the
  gated type. Non-destructive is fine for "minimize risk": flag/warn (`isFlagged`) beats suppressing, and
  preserves the offline value. (chat-output safety)
- **Compose: never write `@Composable` state during composition.** A `remember { }` initializer that
  constructs an object whose `init` fires a listener that sets a `mutableStateOf` (e.g. restoring a
  conversation that calls `chat.onChange` → `messages = it`) writes state mid-composition and can throw.
  Construct with no-op listeners, then sync initial values + wire the live listeners in a `LaunchedEffect`.
  (SwiftUI is fine — `@StateObject` init runs before any view body.) (conversation history)
- **Headless `--screenshot` fires before scroll-reveal → blank below-fold captures.** A page that reveals
  sections via IntersectionObserver (`.reveal{opacity:0}` until scrolled in) screenshots BLANK for
  everything below the first viewport, because CLI headless never scrolls. Drive the DevTools Protocol
  instead (`website/scripts/shoot.mjs`): inject `.reveal{opacity:1!important}`, set theme, then
  `Page.captureScreenshot{captureBeyondViewport:true, clip}`. Also: macOS TCC blocks the preview sandbox
  from `os.getcwd()`/opening files under `~/Documents` — pass ABSOLUTE paths and a hard-coded `directory=`
  (`website/scripts/serve.py`), never `python3 -m http.server --directory`. (website tooling)
- **SVG `og:image` / favicon silently unsupported by the consumers that matter.** Social scrapers
  (Twitter/LinkedIn/Slack/iMessage) need a PNG/JPG `og:image`; iOS `apple-touch-icon` must be PNG. Ship
  rasterized PNGs (`website/scripts/rasterize.mjs`) + keep the SVG as the modern `rel="icon"`. (website assets)
- **A model SWITCH frees the working model before the new one loads → a failed load bricks the session.**
  Free-before-reassign (C1) is right for memory, but for a *switch* capture the current model first and
  reload it if the new one fails — don't strand the user with no model. (Also: a picker that lists every
  model with no fitness gate lets a user pick one that can't load.) (audit H1)
- **A fixed `n_ctx` ignores the device memory budget.** The KV cache scales with `n_ctx` and sits on top
  of the weights, so 4096 can OOM a model that "fits" by weights on a tight phone. Scale `n_ctx` by RAM
  (`ContextWindow`). (audit M1)
- **A long synchronous native loop on a Swift `actor` pins a cooperative-pool thread.** The actor's
  serialization is load-bearing for safety (it stops `load()` freeing the context mid-decode), so to move
  the loop off the pool you must REPLACE that guarantee with a lock (`NSLock` + `nonisolated(unsafe)`),
  not just remove it. (audit M2)
- **A PERSISTENT llama context + a stateless "decode the full prompt" API silently ACCUMULATES the KV
  cache.** Each chat turn re-tokenized the whole history and `llama_decode`d it into the *same* context
  that already held the prior turn → duplicated context + full re-prefill every turn (time-to-first-token
  grows with length, SoC re-chews the same tokens). Fix: track the tokens resident in the KV; when the
  new prompt is a strict-prefix EXTENSION of them, decode only the suffix (`KVCacheReuse`); otherwise
  `llama_memory_clear` + reprefill. Fail-safe — a non-append mismatch reprefills (correct, no speedup),
  never corrupts. Keep the mirror in **strict** lockstep: record a token in the mirror ONLY *after* its
  `llama_decode` returns 0 — decode-then-record, never record-then-decode-next-iteration; assign the
  prefill mirror only after the prefill decode succeeds; on ANY decode failure clear KV **and** mirror.
  A mirror even ONE token ahead of the real KV silently corrupts every later reuse. (chat KV reuse)
- **iOS engine (Swift) and Android engine (JNI `.cpp`) silently diverge.** Android decoded with
  `llama_sampler_init_greedy()` (repetitive output) while iOS sampled `top_p → temp → dist` the whole
  time — no test caught it because the kotlinc core check NEVER compiles `jni/llama_jni.cpp` and the
  Compose app build only compiles the Kotlin `external fun` decl, not its C++ body. When you change one
  platform's engine, diff the twin; keep the sampler/param choices identical. Thread params through the
  Kotlin side (CI-compiled) and mirror the *verified* iOS native sequence in the `.cpp`. Structural remedy:
  the JNI decode loop now lives in `jni/llama_generate.h`, shared with the on-device smoke test, so a
  multi-turn equivalence check exercises the EXACT shipped loop (the smoke run gates on it). (android sampling parity)
- **Verify a `#if canImport(X)` / conditional-compile branch is ACTUALLY compiled before trusting it.**
  `swift test` only compiles `LlamaEngine`'s `#if canImport(llama)` body when the vendored
  `Frameworks/llama.xcframework` is present (or `$QUENDERIN_LLAMA_DIR` is set) — otherwise the mock path
  compiles and a wrong native symbol passes silently (CI's iOS job runs the mock build!). Probe it: insert
  a bogus symbol (`GGML_TYPE_NOPE`, `modelParams.use_mmap_BOGUS`) into the branch, expect a compile error,
  then revert. Compiles clean = the branch was excluded and your change was never checked. (canImport probe)
- **Don't force a llama.cpp param the default already handles.** `flash_attn_type` defaults to
  `LLAMA_FLASH_ATTN_TYPE_AUTO` (-1) → llama.cpp enables FA where the backend supports it. Forcing
  `ENABLED` is a no-op at best, unsafe where AUTO would disable it. Read the header's default before
  setting any `*_default_params()` field. (flash-attn AUTO)
- **`$HOME` containment is NOT a secret-read denylist.** A file-read tool driven by untrusted model
  output (prompt injection) that gates only on home-containment + symlink still exposes `~/.ssh`,
  `~/.aws`, browser cookie DBs, `.netrc`/`.env` — they all live inside `$HOME`. Add an explicit
  sensitive-path denylist, checked BOTH before any `fs` call (no existence oracle) AND after
  `realpathSync` (a benign name can symlink to `~/.ssh/id_rsa`). (read_file denylist, audit #4)
- **An Origin check written `if (origin && !allowed)` is bypassed by OMITTING Origin.** Non-browser
  clients (curl, a malicious local process) send no Origin, so the guard never runs → full access.
  Gate on `!isAllowed(origin)` with missing⇒reject; safe because a legit http-served renderer always
  sends Origin. (Still not auth — Origin is spoofable; the real fix is a per-launch token.) (WS origin, audit #2)
- **Loopback binding (`127.0.0.1`) is NOT an authorization boundary on a shared machine, and a token
  any `GET /` can fetch isn't a secret.** A local server/WS that drives an agent needs a per-launch
  token — but deliver it via a channel the attacker's process CAN'T read: Electron `webPreferences.
  additionalArguments` → preload (not another process's argv), or the trusted-client's opened URL
  `?token=`. A cookie/served-HTML token fails: a malicious local process just does `GET /` to receive
  it. Require the token on the WS upgrade AND every mutating route; empty token ⇒ fail closed. Constant-
  time compare. (WS/HTTP token auth, audit #1)
- **A security gate that "downgrades when X is absent" must fail-closed at BUILD time, not warn at
  runtime.** `verifyModelIntegrity` silently fell back to a forgeable 4-byte magic check when `sha256`
  was null. The durable fix isn't a runtime log — it's a CI/parity gate that makes the absent case
  UNSHIPPABLE (fail the build on any null hash), so the weak branch is never the sole defense. (integrity gate, audit #10)
- **Backup rules are an allowlist-by-omission: anything under `filesDir` not excluded IS uploaded.**
  Excluding only `models/` still shipped `conversations/` to Google cloud backup + device-transfer,
  breaking an "on-device only" promise. Exclude sensitive dirs from BOTH `<cloud-backup>` and
  `<device-transfer>` (API 31+) AND `backup_rules.xml` (API ≤30). (Android backup, audit #7)
- **Red CI on a PUBLIC repo is always a real signal — and one red step MASKS the next.** A failing
  `npm audit` step hid a downstream `no-useless-escape` lint error; fixing audit exposed lint, then
  tests. Run the CI job's steps locally IN ORDER (`audit → lint → check → test → build`) before
  pushing, so you don't ping-pong one masked failure at a time. (CI step masking)

## Chronological log (newest first, 5 lines max)

- 2026-06-27 — Tool-loop hardening (deep-hunt): (1) `read_file` leaked a file descriptor —
  `openSync`/`readSync`/`closeSync` with no `try/finally`, so a `readSync` throw (EIO/perms change)
  skipped the close; repeated failures exhaust the fd table (EMFILE) and down the server. Wrapped in
  `try/finally` (`src/services/tools/handlers.ts`). (2) The calculator tokenizer accepted `1.2.3` as one
  number → `parseFloat` silently returns `1.2` (NOT NaN), a wrong answer instead of an error; reject >1
  decimal point (`calculator.ts`). (3) `hasToolCalls` matched only the OPENING `<tool_call>`, so an
  unclosed tag returned true while `parseToolCalls` (needs the pair) found none → loop spins on
  unexecutable output; require a complete pair (`toolLoop.ts`). Tests added. Lesson: `openSync` needs
  `try/finally` like any handle; `parseFloat` is not a validator; a "has X" probe must agree with the
  parser that consumes X.

- 2026-06-27 — Prompt-injection hardening (deep-hunt, `src/services/agent/promptBuilder.ts`): the
  UNTRUSTED DATA fence could be CLOSED EARLY by its own content — `wrapUntrustedData` embedded device
  XML / vision text / attachment names+bodies / corrections verbatim, so a hostile screen showing the
  literal `<<<END UNTRUSTED DATA>>>` (or a `<<<UNTRUSTED DATA:` to spoof a new fence) escaped the fence
  and smuggled the rest out as trusted instructions. Fix: neutralize both markers inside content before
  wrapping. Also: the cross-run trajectory (`pastMemory.actions`) was injected as a trusted `[SYSTEM
  WARNING]` — but it's derived from past runs over untrusted screens, so a poisoned "winning" sequence
  replayed as trusted; now fenced as a PAST_TRAJECTORY_HINT (execution still passes the action gate).
  Tests added. Lesson: a trust-fence is only as good as its delimiter — always strip the sentinel from
  untrusted content, and don't elevate stored agent output to trusted just because the agent authored it.

- 2026-06-27 — Electron hardening (deep-hunt batch, `src/electron/main.ts`): (1) the window had NO
  `setWindowOpenHandler` / `will-navigate` guard, so reflected/injected untrusted content could navigate
  it to a remote or `file://` URL and escape the boundary — pinned all navigation + new-window to the
  local origin. (2) `app.on('activate')` re-ran the FULL `bootstrap()` on a macOS dock re-activate →
  a SECOND backend server (new port) + a leaked Tray + double-registered global shortcuts — split out
  `createWindow()` so re-activate only remakes the window. (3) `findFreePort` recursed with no bound and
  retried EVERY error → infinite port-bumping on EACCES — bounded it (100 tries / >65535) and only retry
  EADDRINUSE, reject otherwise; `bootstrap()` failure now exits cleanly instead of an unhandled rejection.
  Refuted on re-read: the `contextBridge` authToken exposure (intended design; the renderer needs it +
  the nav guard mitigates XSS). Lesson: an Electron window that renders ANY untrusted content needs a
  navigation allowlist + window-open deny; per-activate setup must be idempotent.

- 2026-06-26 — Two download/extract write streams had no `'error'` handler (`src/app.ts` voice-model
  extract; `src/services/llm.service.ts` model download). A mid-write `ENOSPC` (realistic: multi-GB
  model on a ~2-5GB-free disk) emits `'error'` on the write stream → unhandled → uncaught exception →
  process exit; the download loop could also hang at `drain`/`end` once the stream broke, and leaked the
  file handle on a thrown read error. Fix: per-file `'error'` handler in app.ts; in llm.service capture
  the error, resolve `drain`/`end` on `'error'`, throw it so the catch keeps the partial for resume, and
  `destroy()` in a `finally`. Inert on the happy path. Lesson: same as the spawn `'error'` rule — every
  stream/child-process needs an `'error'` handler, and write loops must not hang once the sink errors.

- 2026-06-26 — `AndroidProvider.spawnAdb` had no `proc.on('error')` handler
  (`src/services/providers/android.provider.ts`). When adb isn't installed (ENOENT — platform-tools is
  a separate install), Node emits `'error'` (not `'close'`): unhandled it re-throws as an uncaught
  exception, and the Promise — which only settled on `'close'` — hung until the ~15s ADB_TIMEOUT, so the
  user saw "timed out" for "not installed". Fix: an `'error'` handler that clears the timer and rejects
  with code ADB_MISSING (already routed by the websocket + daemon to a user-facing setup prompt).
  Regression test mocks `child_process.spawn` to emit ENOENT/EACCES. Lesson: every `spawn()` needs an
  `'error'` handler — ENOENT never reaches `'close'`.

- 2026-06-26 — Desktop `unloadModel()` leaked the native model+context (`src/services/llm.service.ts`).
  It nulled `modelInstance`/`contextInstance` but never `.dispose()`d them — and it's the "free RAM"
  path, fired by the idle-timer + memory-pressure auto-unload, so the headline RAM-freeing op freed
  nothing (node-llama-cpp native memory isn't GC-reclaimed promptly); on a long session it grew every
  idle cycle. Same root in the init catch: a model that loaded but whose context creation then failed
  (the OOM fallback chain) leaked because the `model` local was out of the catch's scope. Fix: dispose
  before null in unloadModel; hoist `model`/`context` so the catch disposes a partial load. Regression
  test (inject fake handles, assert dispose+null). Lesson: a native-backed handle must be disposed before
  it's dropped/nulled, not just reassigned — grep every `Instance = null` for a missing `.dispose()`.

- 2026-06-26 — Cross-platform parity SUITES had drifted: Kotlin `CoreVerify.kt` pinned the `\t`/`\n`
  short-escape JSON decode as a parity case; Swift `AgentParityTests.swift` did not (iOS decoded it fine
  via `JSONDecoder` — just untested, so the contract wasn't pinned both sides). The two files were kept
  "in lockstep" by a comment only. Fix: added the missing Swift case, made the vectors canonical in
  `shared/agent-parity-vectors.json` (stable `id`s), tagged each assertion `// parity:<id>`, and added
  `scripts/check_agent_parity.py` + a CI step asserting the bijection. Lesson: a hand-mirrored parity
  suite drifts like a hand-synced catalog — enforce coverage with a checker, not a "keep in sync" comment.

- 2026-06-26 — Intent-classifier cache leaked unbounded via the LLM-fallback path
  (`src/services/intentClassifier.ts`). `classifyIntent` evicted-then-set to honor MAX_CACHE_SIZE=200,
  but `classifyWithLlmFallback` did a bare `cache.set` with NO eviction → a long session of distinct
  low-confidence inputs grew the Map without bound (slow memory leak). Fix: a shared `setCached`
  (evict-when-full) used by BOTH write paths. Pinned with a 260-insert bound test. Lesson: a bounded
  cache with TWO write paths must funnel both through one bounded setter — grep every `.set(` for the unguarded one.

- 2026-06-26 — Desktop agent dropped a valid JSON action when the model added a trailing brace
  (`src/services/agent.service.ts`). The action parser used `indexOf('{')`..`lastIndexOf('}')` — the same
  H13 first-`{`..last-`}` bug the mobile `AgentDecisionParser` already fixed. A second object or a `}` in
  prose over-extended the span → `JSON.parse` threw → the valid first action fell through to the
  (usually-failing) XML fallback → the step was lost. Fix: a brace-walking `firstJsonObject` (skips
  strings) takes the FIRST complete object; exported + unit-tested. Lesson: the H13 pattern lived in
  THREE platforms — re-grep `indexOf('{')`/`lastIndexOf('}')` everywhere when a parser bug is found.

- 2026-06-26 — Desktop calculator disagreed with the mobile twins + standard math on `-2^2`
  (`src/services/tools/calculator.ts`). It put unary minus INSIDE `parseExponent` (`exponent = unary
  ('^' unary)*`) → `-2^2 = (-2)^2 = 4` (the Excel convention); iOS/Android `ArithmeticParser` and
  Python/Wolfram/TI give `-(2^2) = -4`. Fix: hoist unary ABOVE exponent (`unary = ('±') unary |
  exponent`; `exponent = primary ('^' unary)?`) so all three platforms agree on -4. No test pinned the
  old value; added a precedence-parity test. Lesson: the desktop is the "reference" the mobile twins
  were ported from — but the port can FIX a bug the reference still carries; re-diff back to the reference.

- 2026-06-26 — Android background download didn't auto-resume after a constraint drop
  (`ModelDownloadWorker.kt`). WorkManager flips `isStopped` on constraint loss (e.g. Wi-Fi off); the
  engine throws `DownloadCancelledException`, but the worker's generic `catch` returned `Result.failure()`
  — TERMINAL, so the download never auto-resumed (user had to reopen the app). Fix: catch the cancel
  separately → `Result.retry()`, so WorkManager re-runs (engine resumes from the `.part`) when constraints
  return. :app isn't kotlinc-core-tested → verified by CI `assembleDebug`. Lesson: WorkManager pattern above.
- 2026-06-26 — iOS `install()` had no concurrency guard (`OnboardingModel.swift`). A second install fired
  while one was in flight (rapid double-tap, or a Settings model-switch during a download) raced `phase`
  and both called `engine.load` → whichever load finished last won → the WRONG model loaded. Fix: an
  `isInstalling` re-entrancy guard (mirrors `ChatModel.isGenerating`). Test: a gated-load engine holds
  install(a) so a provably-concurrent install(b) is ignored. iOS 186→187. Lesson: @MainActor reentrancy pattern above.
- 2026-06-26 — iOS chat streaming crashed on Clear/History mid-reply (`ChatModel.swift` `send`).
  Captured `let index = messages.count-1`, then wrote `messages[index]` inside `for try await token`.
  `send` is @MainActor but yields at each await, so `reset()` (Clear) or `restore()` (open History)
  could empty/replace `messages` mid-stream → index-out-of-range CRASH (reset) or overwrite the restored
  chat (restore). Fix: track the assistant message by UUID, look it up each token, stop if gone. Android
  core is synchronous (no stream) → unaffected. 2 deterministic race tests (iOS 184→186). Lesson: stale-index-across-await pattern above.
- 2026-06-26 — iOS date tool silently rolled over invalid dates (`AgentToolsExtra.swift` `isoDates`).
  Foundation `DateFormatter` accepts `2026-02-30` (→ Mar 2), `2026-06-31` (→ Jul 1), a non-leap
  `2026-02-29` (→ Mar 1) and computed a day count from a date the user never typed — diverging from
  Android's strict `java.time.LocalDate`, which rejects them. Fix: round-trip validation — reject any
  parse whose `string(from:)` ≠ the input. Pinned both (iOS `DateCalcToolTests`; CoreVerify +2 → 161).
  Lesson: the date-roll-over pattern above. (This one was the iOS side being wrong, not Android.)
- 2026-06-26 — SafetyBlocklist `\b` diverged across platforms (`SafetyBlocklist.kt`). The safety gate's
  single-word matcher uses `\b` on both, but iOS ICU `\b` is Unicode-aware while Android Java `\b` is
  ASCII-only — so `pin` fired on `piné`/`épin` on Android only (a false-block; iOS correctly didn't).
  Fix: `(?U)` on the Android regex makes `\b` Unicode-aware = iOS parity; real keywords + M9 cases
  unchanged. Pinned both platforms (CoreVerify +1 → 159; iOS `AgentParityTests`). Lesson: ICU-vs-Java `\b` pattern above.
- 2026-06-26 — Android agent answers mangled non-ASCII (`AgentDecision.kt` `extractString`). iOS parses
  the planner JSON with `JSONSerialization`; the Android core hand-rolls value extraction (no JSON lib)
  and its one-char unescaper only knew `\n \t \" \\` — so a model that escapes non-ASCII (`café`,
  emoji) rendered as `cafu00e9` on Android only. Fix: a real unescaper handling `\uXXXX` (+ `\r\b\f\/`;
  surrogate pairs free). Pinned both platforms (CoreVerify +2 → 158; iOS `AgentParityTests`). Lesson:
  real-parser-vs-hand-rolled-extractor twins drift on escapes — see the hand-rolled-unescaper pattern above.
- 2026-06-26 — Closed the coverage gap that HID the KV-mirror desync below. The JNI `generate()` had no
  on-device test — the smoke test was separate code. Extracted the KV-reuse loop into a shared header
  (`android/jni/llama_generate.h`) called by BOTH the JNI bridge and `tools/llama-smoketest.cpp`, so the
  smoke run now exercises the EXACT shipped loop. Added a multi-turn equivalence check (reuse output ==
  fresh full prefill, greedy) that `verify-llama-link.sh` greps PASS/FAIL and fails on. Both `.cpp`
  syntax-checked vs real `llama.h`. Lesson: test the SHIPPED loop, not a twin replica (test≠shipped above).
- 2026-06-26 — Android KV-mirror desync (silent multi-turn corruption; `android/jni/llama_jni.cpp:79,119`).
  The JNI twin of the KV-reuse change set `h->cached = newTokens` BEFORE the prefill decode and `push_back`'d
  each sampled token then decoded it the NEXT iteration → on every max_tokens/cancel exit the mirror ran one
  token ahead of the KV, so the next turn's `KVCacheReuse` prefix-match skipped a real token and corrupted the
  context (and a prefill failure left the mirror lying). iOS was correct (records only after a successful
  decode). Fix: port iOS's order — prefill-decode → mirror; sample → decode → push; clear KV+mirror on failure.
  Syntax-checked vs the real `llama.h`; C++ body isn't CI-compiled (see android sampling-parity bullet). Lesson: strict-lockstep bullet above.
- 2026-06-25 — Chat KV-cache reuse (efficiency / "close to the metal"). Both engines kept ONE persistent
  context but re-decoded the full conversation every turn → KV accumulated duplicated history and
  time-to-first-token grew with length. Fix: `KVCacheReuse` (pure, tested both platforms) — decode only
  the new suffix on a strict-prefix append, else `llama_memory_clear` + reprefill (fail-safe). iOS engine
  wired (native calls proven compiled via bogus-probe; swift test 181) + Android JNI mirror (on-device).
  Real-device validation owed (the speedup + output-identity). Lesson: see the persistent-context KV pattern above.
- 2026-06-25 — Native features (PRs #47–48). Model storage management: `ModelManager` over a real
  `FileManagerModelStorage`/`FileModelStorage` + a Settings "Downloaded models" section (per-model size,
  total, swipe-to-delete; active protected). Conversation export: `ConversationExporter` → portable
  Markdown, shared via iOS `ShareLink` / Android `ACTION_SEND`. Both platforms, CI-verified (core unit-
  tested; SwiftUI compiled by `swift test`, Compose by `assembleDebug`). STATUS.md updated. iOS 177 / core green.
- 2026-06-25 — Security-audit fixes, full batch (PRs #34–45, report `docs/audits/2026-06-23-code-review-security-audit.md`).
  ALL 10 HIGHs addressed: #1 per-launch token auth on WS upgrade + every mutating `/api` route (#43/#44; live-
  verify pending) · #2 WS rejects missing Origin · #3 clean builds (stale-dist root cause) · #4 `read_file`
  secret denylist · #7 Android backup excludes `conversations/` · #8 HTTPS-only download · #9 asar (signing=certs)
  · #10 catalog build-gate on missing `sha256`. Plus MEDIUM/LOW: CI supply-chain (least-priv token, kotlin
  checksum, SHA-pinned actions #38) · agent coordinate-click blocklist (#39) · agent wall-clock timeout ·
  cancellable Android download · truncated-download mitigated by the mandatory hash. Un-redded `main` (undici/
  form-data CVEs + a masked lint error). #1 live-verify, #9 signing, #5 privacy-lock need you. Lessons: 7 security patterns above.
- 2026-06-21 — Phone hardware-adaptation batch (PRs #22–31, plan `docs/audits/2026-06-20-phone-hardware-adaptation-plan.md`).
  Shipped: P-core threads (`ThreadPlanner`) · footprint-aware `n_ctx` · honest `unsupported` exit · thermal-adaptive
  threads + in-flight `ThermalGovernor` (iOS calls `llama_set_n_threads` every 32 tokens) · q8_0 KV cache
  (`KVCachePolicy`, ~2× context) · mmap/mlock jetsam guard · Android top-p+temp sampling (was greedy — parity fix).
  Every iOS native field proven compiled via the bogus-symbol probe. iOS 173 / core 149 green. Remaining = on-device
  (Android JNI thermal loop, Vulkan, micro-batch). Lessons: see the parity / canImport-probe / flash-attn patterns above.
- 2026-06-20 — Mobile engineering audit (8 findings) fixed/resolved. Native-engine review for running
  multi-GB models on phones. H1 recoverable model switch · M1 device-aware `n_ctx` (`ContextWindow`) ·
  M2 iOS decode off the cooperative pool (`NSLock` + `nonisolated(unsafe)`) · M3 switch-time cancellation
  (`requestCancel`) · L1 atomic conversation writes · L3 JNI OOM throw; L2 (atomic > append for small
  text) + L4 (Android Vulkan = device milestone) resolved. iOS 153 / core 139 green. See top-section
  patterns + `docs/audits/2026-06-20-mobile-engineering-audit.md`.
- 2026-06-20 — Conversation history wired into both apps (built-but-unwired core). Symptom: core had full
  multi-conversation support (`ConversationManager`/`Library`/`Store`, tested) but neither app exposed it —
  chat showed only the in-memory thread. Fix: `FileConversationPersistence` (kit + core) + a
  `ConversationCoordinator` (restore-recent / persist-per-turn / new / open / delete) + a History sheet
  (iOS `ChatHomeView`, Android `ChatScreen`). iOS 149 / core green. Lesson: Compose composition-write — see pattern above.
- 2026-06-20 — Marketing site world-class pass (no app code). Symptom: site polished but not share-ready —
  SVG-only `og:image` (blank social previews), no PNG favicon/`apple-touch-icon`, no FAQ rich-results, no
  manifest. Fix: `scripts/rasterize.mjs` → og-image.png (1200×630) + favicon-16/32 + apple-touch-icon.png;
  `site.webmanifest`; FAQPage JSON-LD; dual `theme-color` on all 6 pages. Built `scripts/serve.py` +
  `scripts/shoot.mjs` (CDP screenshotter). Verified: assets 200, both JSON-LD valid, a11y focus/scrim intact.
  Lesson: see the two website patterns above. Still user-only: legal placeholders + waitlist endpoint.
- 2026-06-20 — Chat output unmoderated (store Gen-AI gap). Symptom: `SafetyBlocklist` gated agent
  tool calls + final answer, but `ChatModel` returned model chat output verbatim — the Play/App-Store
  "minimize risk of policy-violating output" safeguard was missing on the chat path. Fix: shared
  `ChatMessage.isFlagged` (assistant text tripping the blocklist) + `SupportContact.flaggedOutputNotice`,
  surfaced as a non-blocking warning under flagged bubbles (iOS `ChatView` + Android `ChatScreen`). iOS
  143 / core green. Lesson: gate every producer of the gated type — see top-section pattern.
- 2026-06-20 — Agent halts silently with no answer. Symptom: a goal that hit the step limit, the
  safety gate, or a plan-parse error showed the steps then nothing — user can't tell why it stopped.
  Cause: `AgentSession` publishes `haltReason` but `AgentView` (iOS) / `AgentScreen` (Android) only
  rendered `answer`. Fix: shared `AgentRun.HaltReason.userMessage` (identical strings in QuenderinKit
  + quenderin-core, parity-checked) + a halt banner when `answer == nil && !isRunning`. iOS 139 /
  core green. Lesson: render every terminal state a VM publishes — see top-section pattern.
- 2026-06-16 — Pre-ship review wave 6 (last safe items): M5 unique device-side dump paths + rm (was a
  fixed `/sdcard/window_dump.xml` → stale/mid-write reads under concurrent ADB); M12 hoist `embedText`
  out of the write-lock (was serializing every save behind a 100–500 ms inference); L4 device-side
  delete loop so all 50 deletes fire on Android ≤9. Desktop 57 green. **Only H2/H3 — which need an
  on-device run to fix safely — remain in code; the rest of the deep review is fully remediated.**
- 2026-06-16 — Pre-ship review wave 5 (remaining safe mediums/lows): M8 zip-slip in the voice-pack
  download → per-entry path validation (no more write-outside-voiceDir); M10 Android AgentSession data
  race → @Volatile + re-entry guard + finally; M11 cosine NaN-sort guard; M2 iOS tokenize Int32-overflow
  guard; M3 scripted-engine modelNotLoaded guard; M4 adb `type()` normalizes non-space whitespace; M-surrogate
  title truncation; L5 reject unknown download id (400); L6 diagnosticsId length cap; clamp negative
  headroom (both selectors). Desktop 57 / iOS 134 / core green. Only device-dependent (H2/H3) + a few marginal items remain.
- 2026-06-16 — Pre-ship review wave 4 (more non-blocking): iOS `tokenToPiece` reallocates on a
  >64-byte token instead of dropping it — was garbled output on long Unicode/byte-fallback/special
  tokens (H1); desktop `/api/agent/resume` type+length-guards `manualAction` (a prompt-injection
  vector that coerced non-strings into the LLM context) (M7); `uiParser` no longer registers the
  bounds-less hierarchy root as a ghost id-0 clickable at (0,0) (M6). Desktop 57 / iOS 134 green.
- 2026-06-16 — Pre-ship review wave 3 (non-blocking hardening): desktop `df` shell-injection →
  `execFileSync` (no shell); the agent decision parser now walks balanced braces so a 2nd JSON object
  in one response can't inject a premature answer (Swift returned planError, Kotlin returned it — a
  parity break), iOS+Android (H13); SafetyBlocklist single-word entries use `\b` boundaries so "pay"
  no longer blocks "repay"/"opinion", iOS+Android (M9); Android ConversationStore escapes `\r`
  (data-loss round-trip). Desktop 57 / iOS 134 / Android core green.
- 2026-06-16 — Pre-ship review wave 2 (safety/lock highs): agent `_isRunning` left stuck on a throw →
  permanent dead-lock, fixed with try/finally + an extracted `_runAgentLoop` (H7); unbounded `waitForIdle`
  poll → max-poll cap + cleanup-in-finally (H8); safety-blocklist bypass via `key`/enter + missing
  resourceId & pre-loop goal checks + expanded list (H9/H10); Electron nav-guard `startsWith`→parsed-origin
  + `will-redirect` (H11/H12); safety gate now also covers the agent's final answer, iOS+Android (H14).
  Desktop 57 / iOS 134 / Android core green.
- 2026-06-16 — Pre-submission deep review (18-agent workflow) of the high-risk code the prior audits
  skipped found 5 criticals + 13 highs. Fixed the ship-blockers: iOS model/context leak on re-load (C1)
  + arith-parser stack overflow (C4); Android native-handle use-after-free → lock (C2) + JNI
  pending-exception process-abort (C3, +H4/H5/H6/L3); desktop KV-cache sequence-slot leak →
  autoDisposeSequence+dispose (chat died permanently after one rotation). iOS 134 / desktop 57 / core
  green. Report: `docs/audits/2026-06-16-preship-deep-review.md`. (JNI .cpp compile-checks only in Android Studio.)
- 2026-06-16 — Generative-AI content policy (App Store 1.2 / Play): integrated `SupportContact`
  (disclaimer + report-mailto) on both platforms. iOS views + test were wired; Android twin
  (`SupportContact.kt`) existed but was untested by CI and unwired in the UI. Added 6 checks to
  `CoreVerify.kt` (the kotlinc CI gate) + wired `ChatScreen`/`AgentScreen` (long-press report,
  disclaimer). Lesson: a "twin" file isn't done until its CI harness AND its UI consumer reference
  it — grep the verify harness + the screens, not just the source file. (iOS 134 / core green)
- 2026-06-16 — Store-compliance audit (workflow): native apps are clean (offline, no automation,
  minimal perms) but had 4 submission blockers. Fixed code-side: iOS `PrivacyInfo.xcprivacy`
  (E174.1 + 3B52.1), Android WorkManager `<service> foregroundServiceType=dataSync` (a latent
  `MissingForegroundServiceTypeException` crash on API 34+ mid-download), encryption-exempt key,
  `models/` backup-exclusion. Report: `docs/audits/2026-06-16-store-compliance-audit.md`.
- 2026-06-16 — Adversarial review of the C3 fix found 2 CRITICAL self-introduced bypasses: the
  desktop "already downloaded" early-return skipped verification (`llm.service.ts:667`), and the iOS
  background downloader looked up sha256 by FILENAME not catalog id (`BackgroundModelDownloader.swift:41`)
  → silently magic-only. +6 lower (sha256 OOM trap, finalize cleanup, optional-sha256 export/parity,
  fd leak). All fixed (desktop 57 / iOS 131 / Android green). Report:
  `docs/audits/2026-06-16-c3-ship-readiness-review.md`. Lesson: adversarially review your own security fix.
- 2026-06-16 — C3: model downloads had no integrity check — multi-GB GGUFs streamed to disk and
  handed to llama.cpp's parser unverified (MITM / poisoned-mirror / truncation → RCE surface).
  Fix: real HF-LFS `sha256` pinned per catalog entry + a `ModelIntegrity` verifier (GGUF magic +
  full-file SHA-256) wired into desktop `llm.service.ts`, iOS `URLSession`/`BackgroundModelDownloader`,
  Android `ModelDownloadEngine`; bad file deleted, not resumed. Lesson: verify in the real downloader.
- 2026-06-16 — Catalog `llama32-1b-q2` URL 404'd (`lmstudio-community` has no Q2_K for 1B). Fix:
  repointed to `unsloth` via `scripts/refresh_model_hashes.py`. Lesson: pinned mirror URLs rot —
  verify they resolve (the new sha256 fetch surfaced it).

- 2026-06-15 — Desktop audit batch (C1,C8,C9,H1,H8,H9,H10,H19,H34,M2,M3,M6,M7,M9,M14,M15).
  Symptom: 47-finding consolidated audit. Cause: see patterns above. Fix: PR #7 commits
  06bad21→b62a0da. Lesson: the patterns above. Backlog: `docs/audits/2026-06-14-CONSOLIDATED-open-findings.md`.
- 2026-06-15 — Android app wouldn't build. `MainTabs.kt:50` used `UnitConverterTool`/`DateCalcTool`
  without importing them; no `gradle.properties` (`useAndroidX`); no Gradle wrapper. Fix:
  a5f39bc. Lesson: the headless `kotlinc` core check never compiles `:app` — only a real
  `./gradlew :app:assembleDebug` catches app-module breakage.
- 2026-06-14 — Stale `constants.test.ts` asserted `llama3-8b` at 6GB; logic returns `qwen3-4b`.
  Fix: 46b3165. Lesson: a duplicate test that drifts from the authoritative one is test-rot;
  fix it against the authoritative spec, don't rewrite to match code blindly.
