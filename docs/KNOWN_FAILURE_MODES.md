# Known failure modes — the ledger

The owner's question (2026-07-03): *"You knew repetition was a thing — what else do you
know can go wrong that isn't fixed? What's stopping you from fixing all of it before users
get this?"* The honest answer: nothing except running the enumeration. Domain knowledge
only becomes fixes when someone audits the code against it systematically — so this file
IS that audit, kept current. **Every known failure mode of an on-device LLM chat app is
either ✅ fixed (with the mechanism named), ⏳ planned (with the reason), or 🟨 accepted
(with the justification). Nothing is allowed to be silently known.**

Rules: when you learn a new failure mode (a bug, a paper, a competitor's postmortem), add
a row BEFORE fixing it. When shipping a feature that touches generation, re-read the table.

## Generation quality

| Failure mode | Status | Mechanism / disposition |
|---|---|---|
| Verbatim repetition loops (neural text degeneration) | ✅ | Three layers: sampler repetition penalty (1.1/256, `LlamaEngine`) · mid-stream loop tripwire (`DegenerationGuard.looksDegenerate`, every 32 tokens) · settle-time collapse of identical paragraph runs. Tests both platforms. |
| Split multi-byte characters across BPE tokens → "�" corruption (Cyrillic = 2 bytes, emoji = 4) | ✅ | `UTF8StreamDecoder` holds incomplete trailing sequences until continuation arrives; exhaustive every-split tests. **Android JNI (2026-07-09):** C++ twin in `llama_generate.h` reassembles across pieces before `make_jstring`; Kotlin twin unit-tested in CoreVerify. |
| Zero-token generation → silent empty bubble | ✅ | Settle-time notice: "The model returned an empty reply…" (`ChatModel`), test pinned. |
| Token-cap hit mid-sentence ("…accustomed to the") | ✅ | Engine sets `hitTokenCap` when decode produces full `maxTokens` (Android JNI); iOS ChatModel counts streamed pieces ≥ `options.maxTokens`. UI: "Continue" chip (ChatView / ChatScreen) → `continueLast()` sends a no-repeat cue. Auto-trimming still rejected. |
| Small-model paraphrase rambling / factual errors | 🟨 | Capacity, not sampling — no setting fixes it. Mitigated honestly: per-model quality grades, the Low-quality heads-up in the empty state, the router offering bigger installed models, Stop button. |
| No image/document attachments although the models support them (Gemma 4 is omni, Gemma 3 has vision) | ⏳ | **Vision/mtmd still out** (xcframework rebuild + mmproj catalog). **Text documents in chat: ✅** iOS attach + `DocumentTextExtractor`; Android Compose attach (SAF → extract bytes → `ChatModel.send` documents + chips/rejection) as of 2026-07-09. **PDF text: ✅** iOS via PDFKit; Android pure-Kotlin content-stream parser (Tj/TJ/FlateDecode, cap-aware, scans refused honestly — no OCR). Vision still separate. |
| Same model downloaded twice on one machine (app stores in Application Support, CLI/desktop in ~/.quenderin/models) | ✅ | Mac app default is now `~/.quenderin/models` (shared with CLI/desktop). `FileManagerModelStorage` + `legacyModelsDirs()` still **read** Application Support so pre-unification installs keep working; new downloads write only to the unified dir. |
| Context overflow mid-conversation | ✅ | Budget-windowed history (`ConversationContext`) + engine treats mid-stream decode code 1 as graceful stop, keeping partial output. **Android (2026-07-05):** the trim budget now derives from the engine's REAL loaded `n_ctx` (`LlamaEngine.loadedContextTokens`, often 512–2048 on phones), threaded into `windowedHistory` — was a hardcoded 4096 that silently overflowed the native window (Q-167). |
| Wrong/missing chat template (role bleed-through, "User:" artifacts) | ✅ | The model's own template via `llama_chat_apply_template`, with flat-transcript fallback; caught originally by looking at real output. |
| Thermal throttling turning replies to sludge | ✅ | `ThermalGovernor` re-tunes thread count mid-generation. |

## Interaction robustness

| Failure mode | Status | Mechanism |
|---|---|---|
| Reentrancy: clear/open/switch DURING a streaming reply | ✅ | iOS: stream writes track the message by stable id, re-looked-up per token; install/switch re-entrancy guards. **Android (2026-07-05):** `send` runs on a real background thread, so the id-relookup alone wasn't enough — `ChatModel` now carries a monotonic generation id + `synchronized` transcript, and `reset`/`restore`/`persist` `stopGenerating()` (bump id + `engine.requestCancel()`) before mutating, so a zombie send's writes/settle no-op (Q-004/Q-168). CoreVerify pins the mid-stream restore/reset/double-send cases. (Bug journal: `@MainActor`+`await`; single-threaded guard doesn't port.) |
| Runaway generation burning battery | ✅ | maxTokens cap + Stop button + degeneration tripwire. Stop now calls `engine.requestCancel()` so the native decode is interrupted mid-prefill too (was flag-only: dead during prefill, one-token-late otherwise — Q-005/Q-217); the prefill decode is bracketed by a `cancelState` check. **Android (2026-07-05):** `ChatModel.stopGenerating()` + a real Stop button on the composer (was a bare disabled composer), and the mid-stream `DegenerationGuard.looksDegenerate` tripwire now fires every 32 tokens → `requestCancel()` (Q-005/Q-237), matching iOS. |
| Download corruption / tampering | ✅ | SHA-256 / GGUF-magic gate on every path (onboarding, library, bulk, drag-import); corrupt files deleted, never listed. Concurrent writers to the SAME target file are excluded by `DownloadCoordinator` (single in-flight guard keyed by filename — Q-003); drag-import checks a catalog match against its pinned SHA-256, not magic-only (Q-010). |
| Disk full mid-download | ✅ | `DiskSpace` preflight before the tap; bulk-download offered only with ≥10 GB headroom. |
| Interrupted downloads | ✅ | Resumable background session; survives relaunch (verified live 2026-07-03). |
| Dead / renamed catalog URL, or a non-2xx server body (404 "Entry not found", 429 throttle, gated wall) written to disk and misdiagnosed as an integrity failure | ✅ | Downloader rejects non-2xx in `ChunkedDownloadDelegate.didReceive response` BEFORE writing a byte → a clear `.transport(HTTP <code>)`, never the error-page body reaching the GGUF gate as a cryptic `ModelIntegrityError`; `describe()` gives integrity errors a human sentence. **Root cause fixed** (App Review 2.1a, 0.2.0(9)): `ggml-org/gemma-4-12B` 404'd (no Q4_K_M quant there) and was the 16 GB-Mac auto-pick → "ModelIntegrityError error 0"; repointed to `unsloth/gemma-4-12b-it-GGUF` (real SHA, all 4 twins). CI guards: `scripts/check_catalog_urls.py` (live-URL) + `check_catalog_parity.py` (twins agree). |
| Model too big for RAM (jetsam / OOM) | ✅ | `MemoryFitness` gates every offer surface (picker, library, presets, router). |
| Surprise multi-GB downloads from a settings tap | ✅ | Speed dial confirms before fetching (2026-07-03). |
| Quit mid-generation loses the partial reply | 🟨 | Accepted: persist-on-turn-end is the consistency boundary; a mid-token crash-safe journal isn't worth the complexity today. |

## Safety / store compliance

| Failure mode | Status | Mechanism |
|---|---|---|
| Harmful autonomous agent actions | ✅ | `SafetyBlocklist` hard-gates tool calls (pay/delete/credentials…); parity-tested both platforms. Desktop device agent: audit ledger + bulk brake + **opt-in per-run mission approval** (Q-549 Step 3, `setMissionApproval` / Settings toggle / `QUENDERIN_MISSION_APPROVAL`, fail-closed; Allow dialog Escape = decline). |
| Objectionable AI content presented as fact | ✅ | Standing disclaimer under chat + agent; flagged-output notice; per-response Report → support email. |
| Prompt injection via second JSON object in agent output | ✅ | First-complete-object parsing, parity-pinned (H13). |
| Single-window Mac app: closing the main window leaves no way to reopen it | ✅ | `applicationShouldTerminateAfterLastWindowClosed → true` (`QuenderinApp.swift`): quit-on-last-close, Apple's sanctioned single-window remedy (App Review 4.0.0 Design, 0.2.0(9)). All state persists continuously; relaunch restores the active model → `.ready` and the most-recent conversation. Settings (⌘,) is a separate window, so this fires only once the LAST window closes. |

## Cross-platform drift (the meta-failure)

| Failure mode | Status | Mechanism |
|---|---|---|
| Twin logic diverging silently (Swift ↔ Kotlin) | ✅ | Machine-enforced parity: catalog, agent vectors, router vectors (CI); CoreVerify mirrors for guards. |
| Android lag list (JNI: repetition penalty, per-piece UTF-8 decode; UI backlog) | ✅ | Mid-stream abort + reentrancy/Stop/degeneration (2026-07-05). **2026-07-09:** chat-path sampler now installs `penalties(1.1/256)` matching iOS; UTF-8 stream decoder in JNI. Remaining UI backlog is product polish, not a correctness chip. |
