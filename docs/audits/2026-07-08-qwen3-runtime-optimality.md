# Qwen3-4B Runtime Optimality Audit — Mac Agent Surface

**Date:** 2026-07-08
**Scope:** `apple/QuenderinKit/Sources/QuenderinKit/{LlamaEngine,AgentLoop,InferenceEngine,AgentDecisionGrammar}.swift` (Mac agent), with one item on `src/` (Electron/TS, non-Mac product).

## Overall verdict

Qwen3-4B is run sub-optimally on the Mac app's **agent** surface, via two coupled structural gaps plus a smaller sampling-recipe mismatch. The **Chat** surface is correct (real ChatML template + deliberate no-think close). None of that reaches the agent loop: an agent turn gets a raw flat `Goal:/Available tools:` string (no ChatML) and is grammar-forced to emit `{` as its first sampled token, so the model runs both out-of-distribution and with zero deliberation budget. The JSON contract itself, the grammar, and the stall/fabrication guards are solid and not in question.

Two of the five issues below are **RISKY** — real problems whose *proposed* fixes are incomplete or would themselves regress (untested stop-sequence plumbing, thinking-mode coupling that fights the grammar and the deliberate action-first design). Both need a scoped, smaller-blast-radius fix than what was originally proposed, plus a product decision (they reverse a deliberate thinking-OFF / Gemma-tuned design and require an Android/Kotlin twin update for parity). One issue is a clean **SHIP** on iOS only (sampling recipe), one is **REJECT** (by-design guard, not a defect), and one is **SHIP** but out of scope for the Mac agent (TS/Electron chat robustness).

**Priority for an implementation pass:** do #3 (sampling) first — it's cheap, isolated, and has zero coupling risk. Treat #1 and #2 as one combined product decision (they must land together or not at all) and scope them down from the original proposal before touching code. Leave #4 alone. Do #5 only if the Electron/CLI build is also in scope for this pass.

---

## Issues

### 1. Agent decision grammar masks `<think>` from token 1 — reasoning-budget fix

**Rating: RISKY** (real problem, proposed fix regresses / is incomplete)

**File:line:**
- `AgentDecisionGrammar.swift:17` — `root ::= ws ( tool | plan | answer ) ws`
- `AgentDecisionGrammar.swift:25` — `ws ::= [ \t\n\r]*` (whitespace-only; `<think>` starts with `<`, unsampleable)
- `LlamaEngine.swift:354-358` — grammar sampler inserted first, applied from generation token 1
- `AgentLoop.swift:105-106` — agent path uses `engine.complete(...)`, never reaches the no-think machinery at `LlamaEngine.swift:209-216`

**Confirmed real:** the agent decision genuinely gets no `<think>...</think>` span before committing to a tool call — the grammar structurally forbids it from token 1.

**Why the original fix is not safe to ship as specified:**
- `GenerationOptions.stopSequences` (`InferenceEngine.swift:14`) is **defined but never consumed** — the generation loop (`LlamaEngine.swift:441-477`) only stops on cancel/EOG/maxTokens/decode-error. A two-pass "unconstrained think, then constrained JSON" design depends on a `</think>` stop sequence that does not exist yet. As specified it is not a minimal change — it requires first implementing stop-sequence scanning in the engine, in both languages (Swift + Kotlin twin).
- Without that stop, an unconstrained think pass runs to the full cap (192-256 tokens) every step, then force-appends `</think>` mid-thought. A truncated chain-of-thought can lock the model into a wrong partial rationale — plausibly worse than no reasoning at all — and adds worst-case latency on every one of up to 6 agent steps on constrained hardware.
- Qwen3 routinely thinks 500-2000+ tokens; a 192-256 token cap is near-certain to truncate mid-thought for non-trivial goals.
- This reverses a deliberate, twin-locked, tested design (thinking OFF, action-first, grammar SHA-pinned across Swift/Kotlin) rather than fixing an oversight — it is a product decision requiring the owner's sign-off and a matching Kotlin twin change, not a unilateral bugfix.

**Exact minimal change (rescoped — do this instead of the original two-pass proposal):**
1. First implement stop-sequence support in `LlamaEngine`'s generation loop (`LlamaEngine.swift:441-477`): scan the trailing decoded text against `stopSequences` each iteration and break cleanly when matched. This is a prerequisite, not optional — ship it as its own reviewable change with its own test.
2. Only then add the bounded think pass in `AgentLoop.run`: one unconstrained generation seeded with `"<think>\n"`, `stopSequences: ["</think>"]`, hard `maxTokens` cap (start at 384-512, not 192-256, given Qwen3's typical thinking length), no grammar. Append `<think>` + thought + `</think>\n` to the transcript, then run the existing `decisionOptions`/`actionFirstOptions` decode unchanged.
3. Gate the whole feature behind a flag defaulting OFF, ship it experimentally, and measure tool-selection accuracy and latency before flipping the default. Do not widen the grammar in-place to admit `<think>...</think>` inline (`root ::= ws think? ws (...)`) — that risks the model never closing the tag and burning the entire step budget with no backstop.

**Expected impact:** potentially the largest lift in tool-selection and argument-construction quality — this is the mechanism most likely to separate weak from strong Qwen3-4B agent behavior, *if the truncation risk is actually controlled*.

**Regression notes:**
- Latency: adds up to hundreds of tokens of generation per agent step; multiply by up to 6 steps. Must be benchmarked on the lowest supported `deviceBudgetGB` tier before shipping.
- Truncated-reasoning risk is real and must be measured, not assumed away — a chopped `<think>` block can be actively misleading rather than neutral.
- Requires the Kotlin/Android twin to move in lockstep (agent-parity vectors + CI) or parity CI breaks.
- Is a reversal of a deliberate product stance (thinking OFF for agent decisions) — needs explicit owner approval, not just an implementation ticket.

---

### 2. Agent path bypasses Qwen3's ChatML template — flat prompt vs. chat surface

**Rating: RISKY** (real inconsistency, but proposed fix bundles in issue #1's regression)

**File:line:**
- `AgentLoop.swift:105-106` — `engine.complete(prompt: transcript, ...)`
- `InferenceEngine.swift:111-117` — `complete` → raw `generate`, no template applied
- `AgentLoop.swift:315-332` — flat preamble, no `<|im_start|>`/`<|im_end|>` markers
- `LlamaEngine.swift:154-218` — `generateChat`/`buildChatPrompt` apply the real GGUF chat template, but only reached via `ChatModel.swift:117` (Chat surface)
- `LlamaEngine.swift:149-153` — the code's own comment: a flat transcript "makes models ramble hallucinated turns (caught live on the macOS client)"
- `LlamaEngine.swift:339` — BOS added on tokenize (confirmed a no-op for Qwen GGUFs with `add_bos_token=false`; not a real bug, just noted in the original diagnosis)

**Confirmed real:** the agent path genuinely never applies the model's chat template; the exact anti-pattern the codebase's own comment warns about (for the chat surface) is present, unaddressed, on the agent surface.

**Why it's RISKY, not a clean SHIP:** the failure mode the comment warns about — rambling/hallucinated turns, no EOS — is **already neutralized** by the grammar (prose is unsampleable; after the JSON object the grammar leaves only EOG). What's left is a softer, unmeasured claim that ChatML framing improves in-grammar tool selection. More importantly, the fix as originally proposed **explicitly couples this change to enabling thinking** ("a variant of `buildChatPrompt` that skips the no-think close, so the two fixes compose") — reintroducing all of issue #1's regressions (grammar has no `<think>` production, so this directly destabilizes the constrained decode unless #1's grammar-widening is also done carefully) and fighting the documented action-first design built for fast decisions from a resource-constrained model.

**Exact minimal change (decoupled from #1):**
- In `AgentLoop`, replace the `engine.complete(...)` call with a chat-structured call: preamble as `system`, running observation log as history — using the existing `buildChatPrompt` template application, but **keeping the no-think close exactly as-is** (do not skip it). The grammar (`decisionOptions`/`actionFirstOptions`) composes unchanged on top of the templated prompt.
- `buildChatPrompt` already returns `nil` (→ flat fallback) when the GGUF has no template, so this is safe for template-less models with no extra branching needed.
- Ship this independently of, and before, any decision on #1. If #1 is later approved, the two are composed then — not now.

**Expected impact:** in-distribution framing and correct turn/EOS handling for the agent surface; likely a modest, not dramatic, improvement in instruction adherence, since the grammar already prevents the specific pathology (rambling) that motivated the chat-template guard elsewhere.

**Regression notes:**
- Verify no double-BOS in practice (Qwen GGUF `add_bos_token=false` makes the tokenizer's `addBOS` a no-op — confirm on the actual model file in use, don't assume).
- Confirm the grammar still starts cleanly immediately after the templated assistant-turn opener.
- Keep the Kotlin `buildChatPrompt` twin in lockstep for parity CI.
- **Do not** ship the thinking-skip variant alongside this — that's issue #1's regression, not this one's.

---

### 3. Sampling recipe: add `top_k=20`, correct `top_p` to Qwen3's published values

**Rating: SHIP** (non-thinking variant only)

**File:line:**
- `InferenceEngine.swift:21-37` — `GenerationOptions` has no `topK`/`minP` fields at all
- `LlamaEngine.swift:354-363` — sampler chain is grammar → penalties → top_p → temp → dist; no `top_k`, no `min_p`
- `AgentLoop.swift:230,233` — agent decode runs bare defaults (temp 0.7, top_p 0.95) plus grammar

**Confirmed real:** the shipped config (temp 0.7 / top_p 0.95, no top_k) matches neither Qwen3 published mode (non-thinking: temp 0.7/top_p 0.8/top_k 20; thinking: temp 0.6/top_p 0.95/top_k 20). It pairs the non-thinking temperature with the thinking top_p and omits the top_k=20 tail cutoff entirely — a genuine hybrid that matches nothing in the model card.

**Why this is a clean SHIP (unlike #1/#2):** the grammar only constrains JSON *structure* — tool name and `input` are free-form strings, nothing enumerates the valid tool set — so the sampling tail genuinely affects argument noise and occasional wrong-tool picks, independent of the grammar question. Adding `top_k` cannot destabilize the constrained decode: the grammar mask (applied first, illegal tokens set to -inf) means `top_k` only ever narrows the surviving *legal* token set; at most JSON structural positions there are fewer than 20 legal tokens anyway, so `top_k` only bites inside free-string spans. This ships the **non-thinking** branch, matching the currently-deliberate `enable_thinking=false` forcing at `LlamaEngine.swift:209-216` — it has zero coupling to the #1/#2 thinking decision.

**Exact minimal change:**
1. Add a `topK: Int32?` field to `GenerationOptions` (`InferenceEngine.swift:21-37`).
2. Insert `llama_sampler_init_top_k` into the chain **before** top_p, i.e. immediately before `LlamaEngine.swift:361`.
3. Set the agent `GenerationOptions` to `temp: 0.7, topP: 0.8, topK: 20` (non-thinking recipe). Do not touch the thinking-mode numbers (`temp 0.6/top_p 0.95/top_k 20`) until/unless #1 ships — that pairing is #1's concern, not this change's.
4. Scope the new default to the agent path only; leave Chat's existing values untouched unless a separate decision is made to align them too.

**Expected impact:** modest, cheap consistency win — tightens the sampling tail to the model's tuned distribution, reducing off-recipe argument noise and rare wrong-token tool picks. Smaller than #1/#2 in ceiling, but far lower risk and no dependency on unshipped infrastructure.

**Regression notes:** low. Purely narrows the candidate set on top of the existing grammar mask; no correctness change to the sampler pipeline order otherwise. Keep the Android/Kotlin sampler twin aligned — note its chain is a fixed *load-time* sampler (`llama_jni.cpp:350-357`) rather than Swift's per-request chain and may be missing the penalties/grammar Swift has per-request, so parity here is more than a one-line mirror; scope that as a small follow-up, not a blocker for the iOS change.

---

### 4. Action-first grammar drops the `answer` arm on step 1

**Rating: REJECT** (by-design guard, not a defect)

**File:line:**
- `AgentDecisionGrammar.swift:35-44` — `gbnfActionFirst` has no `answer` rule
- `AgentLoop.swift:104` — `firstActionStep = goalNeedsAction && steps.isEmpty` selects it
- `AgentDecisionGrammar.swift:28-34` — documented rationale
- `AgentLoop.swift:131-144` — zero-action / fabricated-success backstops
- `AgentLoop.swift:230` (step 2+) — full grammar restores `answer`

**Confirmed real as a code fact, confirmed NOT a defect:** on the very first step of an action-flagged goal, the model literally cannot emit `{"answer": ...}` — it must attempt `tool` or `plan`. This is deliberate: it was built to stop a weak model (Gemma-3-4B, live-caught) from bailing with a premature "I can't do this" apology on a goal it actually had tools for. Three independent backstops already cover the downside: the zero-action guard, the fabricated-success guard, and full-grammar recovery (with `answer` restored) starting step 2. Worst case on a genuinely tool-less goal is one throwaway, still safety-gated tool attempt — cheaper than a premature bail, exactly as the original diagnosis concedes.

**Recommendation:** no code change. This item shares nothing with #1/#2 — the grammar masks `<think>` regardless of whether `answer` is present, so it's orthogonal to the thinking-budget question. Qwen3-4B being a stronger planner than the Gemma model this guard was tuned against is, if anything, an argument for leaving it alone (less prone to the specific failure this prevents; no more harmed by one forced attempt). Matches the existing precedent of not auto-fixing deliberate, tested design (cf. memory: "Q-324/325 are by-design"). Only revisit if logs actually show the no-applicable-tool case biting in practice.

---

### 5. TS/Electron: no repetition penalty; thinking tokens can starve the chat budget

**Rating: SHIP** (out of scope for the Mac agent; include only if Electron/CLI build is in this pass)

**File:line:**
- `src/services/llm.service.ts:1241-1352` (`generalChat`) and the agent equivalent (`~1163-1169`) — no `repeatPenalty`/`dryRepeatPenalty` set anywhere in `src/`
- `QwenChatWrapper.js:15` — `thoughts` defaults to `"auto"`, never overridden for general chat
- `LlamaChat.js:~1975` — `maxTokens` triggers on total generated tokens, including hidden `<think>` segments
- `hardware.ts:166,180,194,209` — `chatMaxTokens` as low as 128-384 on constrained hardware
- Contrast: `InferenceEngine.swift:9-26` (repeatPenalty 1.1, lastN 256) + `DegenerationGuard.swift`, which the TS build has no equivalent of

**Confirmed real:** the TS/Electron build (Win/Linux + lab, not the shipped Mac Swift app) has neither a repetition penalty nor a degeneration guard, so small quantized models can loop paragraphs verbatim; separately, on tight hardware a reasoning-heavy Qwen3 turn can spend its *entire* token budget on hidden `<think>` content and return an empty/truncated visible answer, since the budget check counts thinking tokens.

**Exact minimal change:**
1. Set `repeatPenalty: 1.1` (last 256 tokens) on the node-llama-cpp generation options for both chat and agent paths in `src/`, mirroring the Swift default.
2. Either reserve headroom for thinking separately from the visible-answer budget, or cap/override `QwenChatWrapper`'s `thoughts` for the general-chat path (node-llama-cpp already exposes a first-class `budgets.thoughtTokens` cap per `LlamaChatSession.d.ts:219-225` — use that rather than a vague "reserve headroom" scheme).
3. Scope strictly to the chat path; do not enable thinking on the TS agent's grammar/JSON-schema-constrained path (`agent.service.ts:417` already runs `temperature: 0`, no think budget, by design — leave it exactly as-is).

**Expected impact:** prevents verbatim-loop degeneration and empty/truncated chat replies on constrained Win/Linux hardware. Does not touch Mac agent tool-selection quality — orthogonal to issues #1-#3.

**Regression notes:** low; brings TS in line with already-shipped Swift guards. The grammar mask on the TS agent path is applied after penalties in llama.cpp, so JSON legality is preserved regardless. Bringing `repeatPenalty` to the TS agent path too (not just chat) is a safe adjacent win worth folding in if this pass touches `src/` at all.

---

## Rejected ideas

- **Widening the agent-decision grammar inline to admit `<think>...</think>` before the JSON** (`root ::= ws think? ws (...)`) — rejected as the *mechanism* for issue #1. Risks the model never closing `</think>`, burning the entire step's token budget with no backstop, since stop-sequence handling doesn't exist yet in the engine. The two-pass approach (bounded, separately capped, using a `</think>` stop) is safer *once stop-sequence support is built* — but even that requires the prerequisite work called out above before it's a "minimal" change.
- **Coupling the ChatML fix (#2) to enabling thinking (#1) in one change** — rejected as a bundling error, not because either half is wrong. They must ship independently: #2 (template, thinking still OFF) is low-risk and can go first; #1 (thinking) is a separate product decision with its own regression profile and needs its own sign-off.
- **Re-adding the `answer` arm to the action-first grammar on step 1** — rejected outright (see issue #4). Would reintroduce the exact premature-bail failure the guard was built to prevent; the existing backstops (zero-action guard, fabricated-success guard, step-2 grammar restore) already handle the residual risk more cheaply than a grammar change would.
- **Treating the BOS-duplication at `LlamaEngine.swift:339` as a live bug** — investigated and set aside. Qwen GGUFs ship `add_bos_token=false`, making the tokenizer's `addBOS: true` a no-op in practice; the same code path is already used by the shipping Chat surface without incident. Not worth a defensive fix without evidence of an actual double-BOS occurring on the model files in use.
- **Applying the TS thinking-budget fix (#5) to the TS *agent* JSON path** — rejected as part of #5's core change (only the *chat* path should get thought-budget capping/disabling); however, extending #5's *repetition penalty* (not the thinking cap) to the TS agent path was flagged as a safe adjacent win, not rejected — see #5's regression notes.
