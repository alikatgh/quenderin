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
- **Advertised-but-unimplemented surface.** A prompt/doc/interface lists capabilities the
  executor/provider doesn't implement (dead `pressKey`, advertised `swipe`). Keep the prompt,
  the type union, and the executor in lockstep. (C8, C9)
- **Device/host shell re-tokenization.** `adb shell input text "$x"` is re-parsed by the
  DEVICE shell — single-argv is NOT enough; escape metacharacters + encode spaces. (H1, M9)
- **Resume/Range trust.** A `Range:` request can be answered `200` (server ignores it) — reset
  byte counters; verify a `206`'s `Content-Range` start before appending. (H9)
- **Untrusted XML/entities.** Device/network-sourced XML needs `processEntities:false`. (H34)
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
- **Pinned mirror URLs rot.** A catalog HF URL can 404 (lmstudio-community ships no Q2_K). Verify
  download URLs actually resolve; prefer a mirror that hosts the exact quant.
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
- **Native handle lifecycle: free-before-reassign + serialize access.** Re-`load()` that overwrites a
  `llama_model*`/`llama_context*` without freeing leaks multi-GB until process exit (C1); a free on one
  thread during a native call on another is a use-after-free — serialize load/unload/complete (C2).
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
- **iOS engine (Swift) and Android engine (JNI `.cpp`) silently diverge.** Android decoded with
  `llama_sampler_init_greedy()` (repetitive output) while iOS sampled `top_p → temp → dist` the whole
  time — no test caught it because the kotlinc core check NEVER compiles `jni/llama_jni.cpp` and the
  Compose app build only compiles the Kotlin `external fun` decl, not its C++ body. When you change one
  platform's engine, diff the twin; keep the sampler/param choices identical. Thread params through the
  Kotlin side (CI-compiled) and mirror the *verified* iOS native sequence in the `.cpp`. (android sampling parity)
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

## Chronological log (newest first, 5 lines max)

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
