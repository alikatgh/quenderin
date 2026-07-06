# Cross-platform twin-drift audit — 2026-07-06

iOS Swift (`apple/QuenderinKit/…`) ⇄ Android Kotlin (`android/quenderin-core/…`).
Method: line-by-line twin comparison with a two-skeptic pipeline. A finding is a
**confirmed drift** only when the second skeptic returns `refuted === false`.
Findings the second skeptic refuted are recorded here as REFUTED, not carried into
the fix list.

> **Scope note (honest accounting).** The audit charter named **17 subsystems**, but the
> data delivered to the scribe covered **15**, and the payload was **truncated mid-stream**
> inside the final subsystem (`onboarding-readiness`) — in the second P1 drift's confirm
> reason. Everything received is preserved verbatim in the companion
> `2026-07-06-twin-drift-audit.raw.json`; the truncation point is marked there. The two
> subsystems with no data are listed as **NO DATA** below. Do not read their absence as
> "aligned" — they were simply never scored in the payload.

---

## Verdict summary

| # | Subsystem | Verdict | Confirmed drifts |
|---|-----------|---------|:---:|
| 1 | agent-loop | **DRIFT** | 2 |
| 2 | agent-session | **DRIFT** | 4 |
| 3 | agent-exporter | ALIGNED | 0 |
| 4 | chat-model | **DRIFT** | 3 |
| 5 | conversation-context | **DRIFT** | 1 |
| 6 | conversation-mgmt | **DRIFT** | 4 (1 of 5 refuted) |
| 7 | conversation-exporter | ALIGNED | 0 |
| 8 | degeneration | **DRIFT** | 3 |
| 9 | kv-cache | ALIGNED | 0 |
| 10 | model-recommender | **DRIFT (raised, refuted)** | 0 (1 of 1 refuted) |
| 11 | model-download | **DRIFT (raised, refuted)** | 0 (2 of 2 refuted) |
| 12 | capability-governance | **DRIFT** | 2 |
| 13 | safety-blocklist | **DRIFT** | 1 |
| 14 | thermal-thread | **DRIFT** | 2 (1 of 3 refuted) |
| 15 | onboarding-readiness | **DRIFT** | 2 (payload truncated) |
| 16 | *(not in payload)* | **NO DATA** | — |
| 17 | *(not in payload)* | **NO DATA** | — |

**Totals across the 15 scored subsystems:** 3 ALIGNED, 12 carry a DRIFT verdict.
Of the 12, two (`model-recommender`, `model-download`) had **every** raised drift
refuted by the second skeptic, so they carry **zero surviving drifts** despite the
verdict tag. **24 drifts survived the second skeptic** in total.

---

## Confirmed drifts

Only drifts whose second skeptic returned `confirm.refuted === false`. Grouped by
subsystem, severity-ordered within each.

### agent-loop

**[P1] Mixed plan array (valid object + garbage) → two different tool executions** · both-disagree
- Swift: `apple/QuenderinKit/Sources/QuenderinKit/AgentDecision.swift:39-51`
- Kotlin: `android/quenderin-core/src/main/kotlin/ai/quenderin/core/AgentDecision.kt:25-38`
- **What differs:** Swift's `object["plan"] as? [[String:Any]]` is all-or-nothing — a
  String element cannot bridge to `[String:Any]`, the whole cast nils, and control
  **falls through to the top-level `tool` key**. Kotlin's type-blind `extractArray` returns
  the array body regardless of element types, `splitObjects` silently drops the non-object
  member, the `calls.size == objects.size` guard passes over the survivors, and the `?.let`
  **unconditionally returns a `Plan`** — never reaching the tool fallback.
- **Failure scenario:** `{"plan":[{"tool":"a"},"garbage"],"tool":"fallback","input":"x"}`
  → Swift runs `useTool(fallback)`; Kotlin runs `Plan([a])`. Same model output, two entirely
  different tool executions (different consent UX, different ledgering).
- **Wrong side:** both disagree — Swift's strict cast + fall-through vs Kotlin's presence-based
  extract + unconditional return. Pick one contract and make both match.

**[P2] Plan array of primitives + top-level `tool` → different halt path** · both-disagree
- Swift: `AgentDecision.swift:39-51` · Kotlin: `AgentDecision.kt:25-38`
- **What differs:** For `{"plan":["a","b"],"tool":"calc","input":"2+2"}`, Swift's cast fails
  on the primitives and falls through to `tool` → `useTool(calc)` **executes the calculator**.
  Kotlin enters the plan branch (balanced `[...]`), `splitObjects` finds zero objects → `calls=[]`
  → returns **null** → AgentLoop counts a parse failure, nudges, and halts with `PLAN_ERROR` on
  the second miss — **no tool runs**.
- **Failure scenario:** identical input → tool execution on iOS/macOS vs `PLAN_ERROR` + no side
  effects on Android. Different halt reason *and* different side effects.
- **Wrong side:** both disagree (plan-vs-tool precedence on a malformed plan).

### agent-session

**[P2] `UnitConverter.format` rounding mode differs on negative half-boundaries** · both-disagree
- Swift: `AgentToolsExtra.swift:111` · Kotlin: `AgentToolsExtra.kt:113`
- **What differs:** Swift `(v*10000).rounded()/10000` rounds half **away from zero**; Kotlin
  `Math.round(v*10000)/10000.0` is `floor(x+0.5)`, half **toward +∞**. Agree for positives,
  diverge for negatives on an exact 5th-decimal half.
- **Failure scenario:** `-0.00025` (exactly `-2.5` after ×10000) → Swift `"-0.0003"`, Kotlin
  `"-0.0002"`. Reachable: the parser accepts a leading `-`, and sub-zero temperature conversions
  produce negative results.
- **Wrong side:** both disagree (pick a single rounding mode).

**[P2] `DateCalc` day-offset overflow: graceful on iOS, uncaught crash on Android** · **kotlin**
- Swift: `AgentToolsExtra.swift:196` · Kotlin: `AgentToolsExtra.kt:165`
- **What differs:** Swift `Calendar.date(byAdding:.day,…)` returns `Date?` and never throws.
  Kotlin `LocalDate.plusDays(n)` **throws `java.time.DateTimeException`** on year overflow
  (LocalDate caps at year ±999,999,999) and nothing in `firstInteger`/`DateCalc.evaluate`/
  `DateCalcTool.run` catches it.
- **Failure scenario:** `"2026-06-08 plus 2000000000 days"`. Int-sized offsets from ~3.65M days
  up to `Int.MAX` fit the parse yet overflow LocalDate — a wide, reachable band. Swift returns a
  string; Kotlin throws uncaught, violating the file's "tolerate LLM garbage, never throw" contract.
- **Wrong side:** Kotlin. Wrap `plusDays` in `runCatching`/try and return the graceful fallback.

**[P2] Non-integer numeric results stringify differently (native `Double` formatter)** · both-disagree
- Swift: `AgentTool.swift:44` · Kotlin: `AgentTool.kt:41`
- **What differs:** Swift `String(Double)` vs Java/Kotlin `Double.toString()` use different
  shortest-representation algorithms and diverge on scientific-notation formatting. Shared guards
  (`abs(value) < 1e15` calc; `abs(v) < 1e12` unit-format) mean the same inputs hit the divergent
  branch on both platforms. Same seam in `UnitConverter.format`'s fallback
  (`AgentToolsExtra.swift:111` vs `AgentToolsExtra.kt:113`).
- **Failure scenario:** `2^70` → iOS `"1.1805916207174113e+21"` vs Android `"1.1805916207174113E21"`;
  `"100000 week to ms"` → iOS `"60480000000000.0"` vs Android `"6.048E13"`. Identical numeric value,
  different tool observation fed back into the agent loop.
- **Wrong side:** both disagree (normalize the number→string rendering).

**[P3] Tokenizer numeric-char classification: `isNumber` vs `isDigit()`** · both-disagree
- Swift: `AgentTool.swift:66` (and `AgentToolsExtra.swift:88`)
- Kotlin: `AgentTool.kt:65` (and `AgentToolsExtra.kt:85`)
- **What differs:** Swift `Character.isNumber` matches *any* Unicode numeric (superscripts,
  vulgar fractions, Roman numerals); Kotlin `Char.isDigit()` matches only category-Nd decimals.
  In the **calculator** the divergence is inert (both reject with the identical string). In the
  **unit-parse number-prefix scan** it is observable: `"5² m to ft"` → Swift returns
  "Couldn't read a conversion…", Kotlin parses `5` then fails on unknown unit `"² m"` →
  "Can't convert ² m to ft…". Two different messages, same input.
- **Wrong side:** both disagree (align on `isDigit()`, the stricter/safer choice).

### chat-model

**[P1] Empty-input send: silent no-op on iOS, thrown exception on Android** · both-disagree
- Swift: `ChatModel.swift:86` · Kotlin: `ChatModel.kt:88`
- **What differs:** Swift `guard !trimmed.isEmpty || !documents.isEmpty, !isGenerating else { return }`
  is a **silent no-op**. Kotlin `require(trimmed.isNotEmpty() || documents.isNotEmpty()) { … }`
  **throws `IllegalArgumentException`**. Both files' own docs say empty input should be handled;
  the Kotlin `require` is the outlier — and Kotlin uses silent-return for its *other* guard
  (already-generating), so it is inconsistent even with itself.
- **Failure scenario:** accidental Send with empty composer + no attachments → ignored on iOS,
  crashes the send coroutine / error toast on Android.
- **Wrong side:** both disagree — but the fix is to make Kotlin return `""` on empty input.

**[P2] Degeneration guard: check-before-append vs append-before-check + abort action** · both-disagree
- Swift: `ChatModel.swift:118-120` · Kotlin: `ChatModel.kt:131-138`
- **What differs:** Swift checks `looksDegenerate` **before** appending the current token, then
  `break`s the loop (drops that token; retains 1..31). Kotlin appends **first**, checks a
  one-token-longer string, and on a hit calls `requestCancel()` **without breaking** (retains
  1..32 plus any buffered tail). Two differences: off-by-one on the checked text, and different
  halt mechanism/retained text.
- **Failure scenario:** a model whose repetition first becomes detectable exactly at a 32-token
  boundary → the two platforms keep visibly different partial replies (different truncation point,
  different amount of the looping tail); `collapseRepeatedParagraphs` then runs over different inputs.
- **Wrong side:** both disagree (Kotlin can't `break` from inside the engine callback — its only
  lever is `requestCancel` — but the twins still diverge).

**[P2] Settle source-of-truth: streamed accumulation vs engine return value** · both-disagree
- Swift: `ChatModel.swift:136` · Kotlin: `ChatModel.kt:143`
- **What differs:** Swift settles `assistant.text` (the streamed accumulation; its only source).
  Kotlin settles `reply` (the `completeChat()` return), documented to cover a non-streaming fallback.
  These diverge on the degeneration-abort path (Swift `break`-truncates the stream; Kotlin's final
  `writeAssistant` overwrites with the full engine return, including post-`requestCancel` tokens)
  and on the non-streaming path (Android shows full `reply`; iOS shows empty stream → empty-reply notice).
- **Failure scenario:** identical degenerating generation → Android shows the longer engine-return
  text, iOS shows the break-truncated streamed text.
- **Wrong side:** both disagree (rooted in the AsyncStream-return vs String-return + callback asymmetry).

### conversation-context

**[P1] History trimmed against configured 4096, not the real native `n_ctx` (Q-167 gap on iOS)** · **swift**
- Swift: `ConversationContext.swift:46-66` · Kotlin: `ConversationContext.kt:42-43`
- **What differs:** Kotlin `windowedHistory(history, contextTokensOverride)` budgets against the
  loaded engine's real `n_ctx` (the Q-167 fix). Swift `windowedHistory(_ history:)` has **no override
  parameter** and its `historyBudget` is hardwired to the configured `contextTokens` (default 4096).
- **Failure scenario:** a model loads on iOS with real `n_ctx = 1024` (memory-tight device). Android
  passes `contextTokensOverride=1024` and trims to fit; iOS budgets against 4096, keeps ~4× more
  history, and overflows the actual native window — truncation/garbled output or a native
  context-overflow error. This is the Q-167 regression re-appearing on the platform that never got the fix.
- **Wrong side:** Swift. Caveat: if the iOS engine independently clamps `contextTokens` to real
  `n_ctx` at construction it would mask this — that evidence lives in engine files outside the audited set.

### conversation-mgmt

**[P1] Internal-whitespace collapse: all-Unicode on iOS, ASCII-only on Android** · **kotlin**
- Swift: `ConversationLibrary.swift:70` and `:84`
- Kotlin: `ConversationLibrary.kt:62` and `:79`
- **What differs:** Swift `split(whereSeparator: { $0.isWhitespace })` collapses **all** Unicode
  whitespace; Kotlin `split(Regex("\\s+"))` (no `UNICODE_CHARACTER_CLASS`) matches **only ASCII**.
  Verified empirically (swiftc + kotlinc on this machine).
- **Failure scenario:** `"Café menu ideas"` with a U+00A0 no-break space → iOS collapses it to a
  normal space, Android retains U+00A0. Different persisted/displayed title *and* — because the
  code-point count differs — a possibly different truncation point at the 40/80 cap. Directly breaks
  the cross-platform title parity both files' comments promise.
- **Wrong side:** Kotlin. Give it the same Unicode reach (`Pattern.UNICODE_CHARACTER_CLASS` /
  `[\s\p{Z}]+`, or collapse via `Char.isWhitespace`).

**[P1] `persist()` mid-stream: iOS skips save & keeps generating, Android stops & saves partial** · both-disagree
- Swift: `ConversationCoordinator.swift:63-69` · Kotlin: `ConversationCoordinator.kt:57-68`
- **What differs:** Swift guards `!chat.isGenerating` and **early-returns without saving or stopping**.
  Kotlin calls `stopGenerating()` **unconditionally** then saves the partial transcript.
  `open()`/`startNew()` are identical `persist(); restore()/reset()` wrappers on both sides, so the
  divergence is live.
- **Failure scenario:** tap "Open" on an older conversation while a reply streams → iOS keeps
  generating and persists nothing; Android halts and persists a half-streamed turn. Different
  persisted state *and* different generation state.
- **Wrong side:** both disagree (coordinator state-machine mismatch on the exact path both comment on).

**[P2] Corruption recovery: per-row salvage on Android, all-or-nothing on iOS** · **swift**
- Swift: `ConversationStore.swift:18-25` · Kotlin: `ConversationStore.kt:23-37`
- **What differs:** Kotlin `decode()` is line-delimited: `split("\n").mapNotNull` drops only broken
  rows, keeping every intact one. Swift `decode()` is a single `JSONDecoder().decode([StoredMessage])`
  wrapped in `(try? …) ?? []`, so any structural damage **empties the whole transcript**.
- **Failure scenario:** a transcript file truncated mid-write → Android keeps the intact prefix, iOS
  returns `[]` (whole conversation appears lost). Atomic writes lower the frequency but don't equalize
  salvage behavior (Kotlin's own fallback path is non-atomic; FS/media corruption is uncovered on both).
- **Wrong side:** Swift. Note: not a one-line port — Swift's JSON array format structurally can't do
  line-based salvage without a format change (P2 arguably slightly high).

**[P2] `modelID` + `newChatSignal` wired through Swift, absent from Kotlin** · **kotlin**
- Swift: `ConversationCoordinator.swift:17,73-81`; `ConversationManager.swift:72,79`;
  `ConversationLibrary.swift:15`; `FileConversationPersistence.swift:56,69,80`
- Kotlin: `ConversationCoordinator.kt:70-78`; `ConversationManager.kt:66-76`;
  `ConversationLibrary.kt:8-15`; `FileConversationPersistence.kt:47-65` (all omit the fields)
- **What differs:** (1) `modelID` is threaded through the entire Swift stack (summary field,
  `save(modelID:)`, index persistence, `activeModelID` stamping) so list rows wear the answering
  model's avatar and survive relaunch; Kotlin records no model identity at all. (2) Swift `startNew()`
  uses `defer { newChatSignal += 1 }` so the signal fires even on the empty-chat no-op; Kotlin
  early-returns with no signal, so a second "New Chat" press is a dead no-op.
- **Failure scenario:** iOS list rows show model-family avatars and refocus the empty chat on a repeat
  "New Chat"; Android shows the generic fallback and does nothing. May be platform-staged — flagged for
  the maintainer's call.
- **Wrong side:** Kotlin.

> **Refuted in this subsystem (not counted):** *deleteMany bulk-delete exists only on Swift* (P3) —
> REFUTED as a missing-feature/capability gap, not a per-platform behavioral bug (no Android code path
> currently behaves differently; the failure requires speculative loop-emulation not present in the twins).

### degeneration

**[P2] `looksDegenerate` length unit: Unicode scalars vs UTF-16 code units** · both-disagree
- Swift: `DegenerationGuard.swift:16-21` · Kotlin: `DegenerationGuard.kt:17-21`
- **What differs:** Swift works in Unicode **scalars** (`Array(text.unicodeScalars)`, `scalars.suffix`);
  Kotlin works in UTF-16 **code units** (`text.length`, `takeLast`, `regionMatches`). They diverge 2×
  per non-BMP char. Every length bound, the window slice, and match alignment count a different amount
  of real text. (Kotlin's `regionMatches` at an odd index can even start mid-surrogate-pair.)
- **Failure scenario:** a model loops a paragraph of emoji/astral CJK → Swift's 160-scalar window covers
  ~160 chars, Kotlin's 160-unit window ~80; one platform flags & aborts the stream, the other doesn't.
- **Wrong side:** both disagree. Caveat: `looksDegenerate` is not yet wired into the live Android path
  (JNI can't abort mid-stream yet), so present-day exposure is limited — the drift goes live when that
  seam lands.

**[P3] `collapseRepeatedParagraphs` `minLength` gate: grapheme clusters vs UTF-16 units** · both-disagree
- Swift: `DegenerationGuard.swift:48` · Kotlin: `DegenerationGuard.kt:47`
- **What differs:** Swift `.count` counts extended grapheme clusters (a ZWJ family emoji = 1); Kotlin
  `.length` counts UTF-16 code units (same emoji = 7+). The `>= 40` "substantial enough to collapse"
  gate is reached at different real lengths.
- **Failure scenario:** ~30 duplicated emoji → Swift counts ~30 (< 40, kept), Kotlin counts 60+
  (≥ 40, collapsed). Different final settled text.
- **Wrong side:** both disagree.

**[P3] Whitespace-trim sets not provably identical** · both-disagree
- Swift: `DegenerationGuard.swift:46-48` · Kotlin: `DegenerationGuard.kt:45-46`
- **What differs:** Swift `.whitespacesAndNewlines` vs Kotlin `trim()` (`Char.isWhitespace`). Divergent
  boundary code points: U+0085 NEL (trimmed by Swift, not Kotlin) and U+001C–U+001F FS/GS/RS/US (trimmed
  by Kotlin, not Swift).
- **Failure scenario:** two ≥40-char duplicate paragraphs where one carries a trailing NEL → trimmed-equal
  on Swift (collapsed), trimmed-unequal on Kotlin (kept). (An NBSP intuition would be a false alarm —
  U+00A0/U+2007/U+202F are trimmed by both — but the NEL / U+001C–U+001F cases stand.)
- **Wrong side:** both disagree (make the trim sets explicitly identical).

### capability-governance

**[P1] `executePlan` pre-flight: graceful fail-closed refusal on iOS, uncaught throw on Android** · **kotlin**
- Swift: `CapabilityRunner.swift:174-176` · Kotlin: `CapabilityRunner.kt:103`
- **What differs:** Swift `guard let preview = try? await item.capability.plan(item.input) else { return "Couldn't preview step N (name). Nothing was done." }`. Kotlin `previews.add(item.first.plan(item.second))`
  with **no guard**. A `plan()` that throws is a clean nothing-done refusal on iOS but an uncaught
  exception out of `executePlan` on Android.
- **Failure scenario:** a T2+ capability whose `plan()` inspects a missing/permission-denied path and
  throws → iOS refuses the whole plan cleanly; Android tears down the agent turn. The all-or-nothing
  fail-closed guarantee is lost on Android.
- **Wrong side:** Kotlin (which *did* guard the `run()` loop with `catch (t: Throwable)`, proving
  fail-closed was intended — it just missed the preview call).

**[P2] Single-action `execute()`: preview-failure ledgering enforced on iOS, unenforced on Android** · **kotlin**
- Swift: `CapabilityRunner.swift:109-116` · Kotlin: `CapabilityRunner.kt:44`
- **What differs:** Swift wraps `CapabilityGate.assess(...)` in do/catch that ledgers decision `"error"`
  and returns "Couldn't preview <name>: <error>". Kotlin calls `assess(...)` bare; because `plan()`/
  `assess()` are declared non-throwing, the compiler doesn't force handling — but the JVM's exceptions
  are all unchecked, so a runtime throw propagates: **no `"error"` ledger row**, exception escapes,
  breaking the flight-recorder invariant.
- **Failure scenario:** a mutating capability's `plan()` throws (NPE/IllegalState) → iOS writes an
  "error" ledger row and returns the graceful observation; Android writes nothing and crashes out.
- **Wrong side:** Kotlin (wrap the `assess()`/`plan()` calls in `try/catch(Throwable)`).

### safety-blocklist

**[P2] Single-word boundary: ICU `\b` vs `[\p{L}\p{N}_]` lookaround — combining-mark hole** · both-disagree
- Swift: `SafetyBlocklist.swift:40-41` · Kotlin: `SafetyBlocklist.kt:37` (pattern) + `:48` (use)
- **What differs:** Swift's ICU `\b` counts a nonspacing combining mark (`\p{Mn}`, e.g. U+0301) as part
  of the word — **no** boundary, keyword does **not** match. Kotlin's lookaround excludes `\p{M}` from
  its word class — boundary forms, keyword **does** match. Empirically confirmed on this machine.
- **Failure scenario:** `"pin" + U+0301` (or `pay`/`buy`/`delete`/`password` + any `\p{Mn}` mark) →
  Android blocks (fails safe), iOS/macOS **passes it through** (`isBlocked=false`) and the agent may act.
  A per-platform hole in a hard safety sandbox — the **security-relevant miss is on the Swift side**.
- **Wrong side:** both disagree; the actionable fix is to close the iOS bypass. (Controls all agreed:
  plain `pin`→both true; `opinion`/`repin`/`pin_`/`pin½`/precomposed `piné`→both false.)

### thermal-thread

**[P1] `MemoryFitness` WARNING message: concrete remaining-GB on iOS, vague string on Android** · **kotlin**
- Swift: `MemoryFitness.swift:57` · Kotlin: `MemoryFitness.kt:36`
- **What differs:** Both enter WARNING on the identical condition (`usageAfterLoad > budgetWarning`).
  Swift computes `remaining = freeGB - required` and shows "…will leave only <remaining>GB free.
  System may be slow." Kotlin never computes `remaining` and shows the numberless "…will leave the
  system tight." (BLOCKED and SAFE messages are byte-identical between twins.)
- **Failure scenario:** a model landing between the 0.65 and 0.85 budgets → iOS users get an actionable
  figure, Android users get vague guidance.
- **Wrong side:** Kotlin.

**[P2] `MemoryCheckResult` shape drift (`remainingAfterLoadGB` missing on Android)** · **kotlin**
- Swift: `MemoryFitness.swift:9` · Kotlin: `MemoryFitness.kt:5`
- **What differs:** Swift's result struct carries 6 fields incl. `availableMemoryGB`, `requiredMemoryGB`,
  `remainingAfterLoadGB`. Kotlin carries 5 (`canLoad, severity, requiredGB, availableGB, message`) — no
  `remainingAfterLoadGB`, and the memory fields renamed. Consequently the Kotlin side structurally can't
  carry the headroom number (driving the WARNING-message drift above). The **decisions** (`canLoad`/
  `severity`) are computed identically — same 0.85/0.65 budgets, 1.15/1.30 overhead, `paramsBillions<=3`
  split, formula and branch order — so a decision-vector parity checker passes; the drift is telemetry/UI only.
- **Wrong side:** Kotlin.

> **Refuted in this subsystem (not counted):** *unknown thermal-state fallback (`@unknown default → .serious`
> vs `else → CRITICAL`)* (P1) — REFUTED: the branches map non-isomorphic input domains (Apple's 4-case enum
> vs Android's 7 status ints), Swift's `@unknown default` is unreachable dead code today, and Kotlin's `else`
> legitimately handles EMERGENCY/SHUTDOWN which Apple has no equivalent for. No real hardware condition diverges.

### onboarding-readiness  *(payload truncated after the second drift)*

**[P0] Restore-through-verify SHA-256 gate exists only on Swift; Android loads unverified leftovers** · **kotlin**
- Swift: `OnboardingModel.swift:190-194` · Kotlin: `OnboardingModel.kt:171-173`
- **What differs:** Swift `install()` re-runs `ModelIntegrity.verify(expectedSHA256:)` on any pre-existing
  file and **deletes it on failure**, then re-downloads. Kotlin `acceptAndPrepare()` has **no integrity
  re-verification** — `downloader.download(model)` returns the existing path without re-fetching and the
  file is loaded as-is. Kotlin's `restoreAtLaunch()` comment *claims* the gate re-runs; it does not exist
  in the Kotlin code.
- **Failure scenario:** a GGUF moved into place but the process killed before the multi-GB SHA-256 check
  finished (truncated/corrupt bytes) → iOS re-verifies, deletes, cleanly re-downloads; Android loads the
  corrupt bytes into `engine.load` — the exact failure the C3 integrity gate exists to prevent.
- **Wrong side:** Kotlin. (`OfflineReadiness` twins were compared end-to-end and are aligned.)

**[P1] Disk-space preflight absent on Android; cellular gate runs unconditionally, not only when downloading** · **kotlin**
- Swift: `OnboardingModel.swift:209-229` · Kotlin: `OnboardingModel.kt:156-173`
- **What differs:** Swift runs both the disk-space preflight (`storageCheck` + `guard storage.hasRoom`)
  and the cellular gate **only inside `if !fileExists`** (i.e. only when a download is actually needed).
  Kotlin has **no disk-space preflight anywhere**, and runs the cellular gate **unconditionally at the top**
  of `acceptAndPrepare`, before it knows whether the file already exists.
- **Failure scenario:** (1) on cellular with the model already on disk, a Settings model-switch →
  iOS loads it (gate skipped), Android returns `Failed("connect to Wi-Fi")` despite needing no network;
  (2) a 9 GB model on a nearly-full device → iOS refuses up front with "not enough space", Android starts
  the download and dies partway with a generic "Download failed".
- **Wrong side:** Kotlin.

> **Note:** the source payload was truncated inside this drift's confirm reason, and any further
> `onboarding-readiness` drifts (the summary mentions cancel-recovery items 3 and 4) were **not delivered
> to the scribe**. Treat this subsystem as **partially reported** — re-run to capture the tail.

---

## Fix next

Ordered most-severe first. Platform to change is in **bold**.

1. **`onboarding-readiness` [P0] — Kotlin.** Port the restore-through-verify SHA-256 gate into
   `acceptAndPrepare()` (`OnboardingModel.kt:171-173`): re-verify a pre-existing file against
   `model.sha256`, delete on mismatch, fall through to a fresh download. This is a data-corruption /
   crash gate; it is the highest-severity finding and currently one-sided.

2. **`agent-loop` [P1] — pick one contract, change both.** The mixed/primitive-plan divergence
   (`AgentDecision.swift:39-51` ⇄ `AgentDecision.kt:25-38`) makes the same model output run different
   tools per platform. Decide whether a malformed plan falls through to `tool` (Swift) or hard-fails
   (Kotlin), then make both parsers agree. Covers both agent-loop drifts.

3. **`onboarding-readiness` [P1] — Kotlin.** Add the disk-space preflight and move the cellular gate
   inside the `if !fileExists` branch (`OnboardingModel.kt:156-173`) so an already-downloaded model
   isn't spuriously Wi-Fi-blocked and a doomed download is refused up front.

4. **`capability-governance` [P1] — Kotlin.** Wrap the `plan()`/`assess()` preview calls in
   `executePlan` (`CapabilityRunner.kt:103`) and `execute()` (`CapabilityRunner.kt:44`) in
   `try/catch(Throwable)` that ledgers `"error"` and returns the graceful "Couldn't preview…" refusal.
   Restores the fail-closed pre-flight + flight-recorder invariant. Covers both capability-governance drifts.

5. **`conversation-mgmt` [P1] — Kotlin.** Give the whitespace collapse in `ConversationLibrary.kt:62,79`
   full Unicode reach (`Pattern.UNICODE_CHARACTER_CLASS` / `[\s\p{Z}]+`, or `Char.isWhitespace`) to
   restore the promised title/preview parity.

6. **`conversation-mgmt` [P1] — pick one, change both.** Reconcile `persist()` mid-stream semantics
   (`ConversationCoordinator.swift:63-69` ⇄ `.kt:57-68`): either both skip-and-keep-generating or both
   stop-and-save. Same user action must not leave different persisted + generation state.

7. **`conversation-context` [P1] — Swift.** Add a `contextTokensOverride` parameter to
   `windowedHistory`/`historyBudget` (`ConversationContext.swift:46-66`) so iOS budgets against the real
   loaded `n_ctx` (the Q-167 fix Android already has). First confirm the iOS engine doesn't already clamp
   `contextTokens` at construction, which would make this cosmetic.

8. **`chat-model` [P1] — Kotlin.** Change `send()` (`ChatModel.kt:88`) to return `""` on empty input
   instead of `require(...)`-throwing, matching the iOS silent no-op contract both files document.

9. **`thermal-thread` [P1] — Kotlin.** Compute `remaining` and surface the concrete GB figure in the
   WARNING message (`MemoryFitness.kt:36`), and add `remainingAfterLoadGB` to `MemoryCheckResult`
   (`MemoryFitness.kt:5`). Covers both thermal-thread drifts.

10. **`safety-blocklist` [P2] — Swift (security).** Close the combining-mark bypass: `"pin"+U+0301`
    passes the iOS safety filter. Align Swift's boundary matching with Kotlin's `[\p{L}\p{N}_]` lookaround
    so iOS stops failing open on decomposed-Unicode adjacency.

11. **`agent-session` [P2] — Kotlin.** Guard `DateCalc`'s `plusDays` (`AgentToolsExtra.kt:165`) in
    `runCatching`/try so an overflowing day-offset returns the graceful fallback instead of throwing
    `DateTimeException`.

12. **`chat-model` [P2] — both.** Reconcile the degeneration-guard order/abort (`:118-120` ⇄ `:131-138`)
    and the settle source-of-truth (`:136` ⇄ `:143`). Bounded by the engine-interface asymmetry
    (AsyncStream vs callback+return), so treat as a design reconciliation, not a one-liner.

13. **`agent-session` / `degeneration` [P2–P3] — normalize shared seams.** Align the `Double`→`String`
    rendering, the `UnitConverter.format` rounding mode, the `isNumber`/`isDigit()` tokenizer classification,
    and the scalar-vs-UTF-16 length units + trim sets in `DegenerationGuard`. Lower-severity but they
    compound; batch them as a "twin seam normalization" pass rather than one PR each.

14. **`conversation-mgmt` [P2] — Swift (design call).** Per-row corruption salvage in `ConversationStore`
    can't be ported without a format change to Swift's JSON-array store; and the `modelID`/`newChatSignal`
    gaps may be intentionally platform-staged. These need the maintainer's decision before coding.

### Not on the fix list (refuted — do not act)
- `model-recommender` P2 (bestInstallableModel free-RAM parameter) — inert, defaults to Swift-identical behavior.
- `model-download` P1 (verify gate in app module) and P2 (`resumeOffset` accessor) — architecture/coverage
  asymmetries and a dead unconsumed getter, not behavioral drift.
- `conversation-mgmt` P3 (`deleteMany`) and `thermal-thread` P1 (unknown thermal fallback) — missing-feature /
  unreachable-dead-code, no per-platform divergence on real inputs.

### Data gaps to close
- **Two subsystems (16, 17) were never scored** in the payload — re-run to cover them.
- **`onboarding-readiness` was truncated** after its second drift; its summary implies two further
  cancel-recovery drifts that never reached the scribe. Re-run that subsystem to capture the tail.
