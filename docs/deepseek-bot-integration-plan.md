# DeepSeek Bot ideas and native integration plan

Date: 24 October 2026. Status: **read-only Host/native slice implemented; full workflow remains open**.

Implementation now includes the pinned passive Host route and native Bot list/history.
See the [Sol 6.1 implementation brief](deepseek-bot-sol-implementation.md) for
delivered source, verification and the exact remaining live/native checks. The
phase-level tasks below remain unchecked until their complete exit criteria pass.

This supplements the [native delivery roadmap, section 6](native-connections-roadmap.md#6-full-feature-parity-in-dependency-order). It expands that roadmap's existing DS Bot teams, groups, cards and automation items; it does not replace the core remote-control completion gates. Store submission remains deferred.

## Recommendation

Make Quenderin the native interface to a persistent DeepSeek assistant and, later, a small team on the user's computer. Reuse DS Bot's Host-side implementation and the Remote project's existing Bot bridge. Keep SwiftUI and Kotlin/Compose, existing enrollment, Noise encryption, session history, exact-action approvals and Stop.

The best first result is one persistent bot that remembers approved preferences, answers a question while working, asks the user for structured input, and resumes the same work after the phone reconnects. Teams come after that journey works reliably.

These are useful additions to Quenderin, not claims that DS Bot invented the techniques. Upstream itself credits Codex, Hermes, AgentMemoryRepo and other projects in its [NOTICE](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/NOTICE).

## Evidence and compatibility baseline

| Component | Inspected baseline | Consequence |
| --- | --- | --- |
| DeepSeek Bot | [0.2.1 release](https://github.com/Fei2411/DeepSeek-Bot/releases/tag/v0.2.1), source `1bebe826f74e9a72cabafd3b80602b05af867b38` | Community Harness plugin, Apache-2.0; preserve LICENSE and applicable NOTICE when reusing source. It is not an official DeepSeek product. |
| Bot runtime compatibility | [Plugin README](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/README.md) lists Harness `0.2.1-rc.2` Web and `0.2.0-rc.2` Web/Desktop | Quenderin's `0.2.1-rc.1` fixture now proves the passive store/channel read through authenticated Remote. Full Bot startup compatibility remains unproven. |
| Remote integration | [`ds-harness-remote` Bot bridge](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/packages/plugin/src/plugin-route-bridge.ts), revision `9a60e783ec1ceaff6116b0462a2863f07f602a55` | Already contains a Bot route bridge and a TypeScript Android client. Adapt their protocol and mapping; these are references, not a drop-in Swift/Kotlin SDK. |
| Quenderin | Local source `1fb1b4416a0ad102141c8a20b5d98e1495eb046f` | Core remote source/fixture/hosted-build evidence is recorded in the roadmap. Live enrolled Host, signed native interaction and later parity remain separate open gates. |

The original assessment inspected source only. The subsequent [Host run](https://github.com/alikatgh/quenderin/actions/runs/40084776342) validates the pinned passive store/channel combination with synthetic state, without invoking the complete Bot entry point or a real model. The implementation brief separates that evidence from pending live and signed-native checks.

## Ideas worth adopting

Effort describes relative integration work after the shared bridge exists: **S** is a narrow projection/control, **M** adds Host and native state, **L** adds execution or recovery semantics. These are not delivery-date estimates.

| Idea | Benefit in Quenderin | Easiest sensible integration | Priority / effort |
| --- | --- | --- | --- |
| Persistent named bots | A stable assistant with its own role, instructions, model and working folder, across many session parts | Reuse Host roster and part mapping; add a native Bots list and details. Keep bot identity separate from current session ID. [Roster](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/host/roster.js) | First / M |
| Scoped, editable memory with provenance | Preferences and decisions survive new chats; the user can inspect, correct and forget them | Reuse Bot/group/team memory and change journal. Start with explicit saves and source links; make automatic extraction opt-in and metered. Never import local Quenderin memories automatically. [Memory documentation](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/README.md#memory) | First / M |
| Searchable continuity across long chats | Long tasks retain unfinished requirements and exact original messages | Reuse the context steward, checkpoint/handoff records and Host FTS5 index. Show part/checkpoint provenance when requested; keep original history authoritative. [Steward](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/host/steward.js), [index](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/host/chat-index.js) | First / M–L |
| Side questions while work continues | “Why are you doing that?” gets an answer without interrupting the task | Adapt `/btw`: a bounded snapshot-based side call, no tool execution, separately stored card, independent cancellation and usage. Explicitly promote to the main conversation only if the user chooses. [Implementation](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/host/btw.js) | First / M |
| Structured questions and result cards | Answer choices/forms, review tables, see progress and charts directly in native UI | Adapt `ask_user` and the bounded `show_view` schema to native components. Start with text, choices, forms, metrics, tables and progress; add charts later. [Schema](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/shared/views.js) | First / M |
| Coordinator-led teams | One bot delegates to a researcher or reviewer and brings back a combined result | Reuse group admin routing and parent/child handoffs. Default to one coordinator responding; specialists run only when selected or delegated within limits. [Groups](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/host/groups.js), [handoffs](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/host/handoffs.js) | Second / L |
| Visible delegated work and explicit chat references | See who is working, who is waiting, and which context was shared | Project Host work IDs, parent links, statuses and source references into native activity rows. Share selected context snapshots explicitly; never give a group every private transcript. [Delivery](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/host/delivery.js) | Second / M |
| Reusable capability packs | Assign a known set of skills/MCP tools to a bot without configuring it repeatedly | Reuse the Host library; initially expose only already-installed, approved packs. Show effective permissions, workspace and changes before attachment. [Capabilities](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/host/capabilities.js) | Second / M–L |
| Per-bot permission presets | Separate a read-only reviewer from a bot allowed to modify a workspace | Display Host-enforced effective policy, including group overrides. Human-only permission elevation; roles such as “Chief” confer no implicit Quenderin trust. A folder is not a sandbox. [Permissions](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/host/permissions.js) | First visibility, later edits / M |
| Complete usage accounting | Explain the hidden overhead of memory, checkpoints, side questions and delegation | Reuse Host usage rows, add native totals by bot/model/task and call purpose. Upstream records tokens, not prices; label unavailable or estimated data honestly. [Usage](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/host/usage.js) | First / S–M |
| Durable scheduled tasks | A bot can perform a defined task later on the computer | Reuse the optional Harness scheduler only after durable command admission and aggregate limits. Start with one-shot tasks, then finite recurring schedules and delivery history. [Schedules](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/host/schedules.js) | Later / L |
| Capability-aware images and web search | Use the selected model's real abilities and show where evidence came from | Reuse Host adapters only where configured: explicit vision fallback disclosure and search-backend attribution. No silent additional provider or billable fallback. [Images](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/host/images.js), [search configuration](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/README.md#web-search) | Later / M–L |

Host browser control, external connectors and arbitrary HTML views are later optional parity work. They add substantial privileges and are not prerequisites for a useful remote assistant. Preserve the existing file/terminal milestones instead of treating these as shortcuts around them.

## Reuse boundaries and custom work

```text
SwiftUI / Compose: Bots, chat, questions, memory, activity, usage
    -> existing enrolled and encrypted Remote connection
    -> reviewed Bot operations through existing plugin.route.call
    -> Quenderin Host policy / compatibility adapter
    -> pinned DS Bot runtime -> pinned Harness -> Host tools and provider
```

The Host remains the sole execution and storage authority. Native clients keep bounded display/recovery caches and deliberate command receipts. Neither phone starts a second agent loop. This extension belongs to **My computer**; direct DeepSeek and on-device chats retain their current behavior.

The existing wire request is `plugin.route.call` with `{route:"api/bot", body:{endpoint,payload}}`, returning `{status,json}`. Prefer its official in-process Fetch/Remote Peer dispatcher; the phone does not need browser cookies. Keep its fixed route boundary and narrow the operation/field policy for Quenderin. The loopback compatibility fallback needs separate review before use. [Protocol](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/packages/protocol/src/index.ts#L542-L550), [dispatcher](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/packages/plugin/src/plugin-route-dispatcher.ts#L8-L53)

Reuse upstream roster, memory, checkpoint/index, handoff, usage and schedule services. Adapt the Remote bridge and Android mapping rather than its whole application. Custom code is necessary for the Swift/Kotlin presentations, versioned cross-platform DTOs, narrow Host authorization and reliable command recovery: upstream does not supply a ready-made SDK with Quenderin's policies.

Quenderin already has SkillMemory, approved Hy-Memory proposals, desktop memory and capability catalogs. Reuse their consent and presentation patterns; do not create a competing local memory engine or require a model-weight download for remote memory.

### Compatibility and safety differences to resolve

1. **Route availability is not plugin compatibility.** `plugin.route.v1` only means the Remote Host can forward a route. Negotiate DS Bot version and individual supported features separately. Quenderin's [Host method policy](../native/remote-host/tools/prepare_host.py) and native codecs now admit only the reviewed passive read contract; later operations require their own policy and tests.
2. **No broad proxy or raw state export.** DS Bot uses browser-authenticated `POST /api/bot`; its state includes management metadata. The existing Remote bridge passes its JSON response. Filter fields on the Host before encrypted transmission, then validate native DTOs. Keep install/update, provider-key, secret-value, browser-cookie, arbitrary URL and terminal routes outside the initial contract. Remote already excludes many administrative operations; preserve those exclusions rather than enabling every DS Bot endpoint. [Bridge and validation](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/packages/plugin/src/plugin-route-bridge.ts#L7-L87)
3. **A nominal read may have effects.** Upstream `state` can bootstrap the team, while `memory-ask` can call a model and change memory. Build a genuinely read-only roster projection; classify operations by actual effects, not their names. [Channel implementation](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/host/channel.js#L134-L147)
4. **Mutations need durable identities.** Upstream `send` creates a fresh request UUID; an RPC acknowledgement alone cannot prevent replay. Reuse Quenderin's command journal and add Host-side atomic reservation, outcome reconciliation and restart tests before automatic retry. Questions/cards bind their exact pending record, revision and scope; a form confirmation never substitutes for a tool approval. [Send and card handlers](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/host/channel.js#L351-L426)
5. **Secrets UX is useful; storage/execution policy needs to stay stronger.** Upstream documents masked input, a local JSON store and shell-environment injection, with exact-value redaction limitations. Reuse only a nonsecret “configure on your computer” request/status card initially. Keep provider values on the Host, preserve native secure storage, and use the existing Varlock/self-hosted Infisical workflow where applicable. Do not copy the secret store, import browser cookies or claim masking isolates a secret from a process. [Documented limits](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/README.md#secrets)
6. **Memory sharing is an explicit policy.** Upstream injects bot/team memory and group memory in group sessions. Group transcript separation alone therefore does not prove total information isolation. Define allowed scopes, source provenance and user-controlled sharing; treat retrieved content as data rather than authority. Rebuildable indexes must not become the only copy of history.
7. **Do not inherit all defaults.** Inspect bootstrap greetings, automatic memory review, restart resume, search-provider overrides and update checks before loading the plugin. Disable unneeded background work in the test profile. The package's [profile patch](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/cordis.patch.yml) changes search configuration; installing it is not a neutral UI-only operation.
8. **Streaming is a projection.** DS Bot also supplies an [SSE feed](https://github.com/Fei2411/DeepSeek-Bot/blob/1bebe826f74e9a72cabafd3b80602b05af867b38/ds-bot/src/host/feed.js). Existing `api/bot` forwarding does not automatically support that stream. Initially reuse Harness streams plus bounded foreground state refresh; add a negotiated Bot feed later if needed. Recover from authoritative snapshots/history, not an assumption of replayable SSE.

## Ordered to-do list

Every item below is future implementation or validation. Use the existing roadmap to record delivery evidence and link the relevant PRs; this file is the detailed design supplement.

### 0. Prove the smallest compatible Host integration

- [ ] Pin DS Bot source/package integrity and a supported Harness/Remote/Node combination. Exercise current rc.1 first; if rc.2 is required, isolate the upgrade and rerun existing approval, Stop, history and crypto compatibility checks.
- [ ] Audit applicable Apache-2.0/MIT notices and dependency changes; retain notices for actual reused modules.
- [ ] Extend the existing official-runtime fixture with one DS Bot, scripted model replies and inert tools. No real credentials, model downloads or background services.
- [ ] Identify and disable unintended install/startup side effects. Verify plain Harness sessions still work when Bot support is absent or disabled.
- [ ] Define a negotiated Bot capability/version contract and shared Swift/Kotlin fixtures. Draft capability names, if used, must be marked Quenderin extensions rather than upstream guarantees.

**Exit:** a pinned fixture can discover one existing bot and its authoritative current session through the reviewed bridge, with no model request caused by listing it.

### 1. Ship the read-only native Bot library

- [ ] Add Host-side minimal projections for bot roster/details, current part, actual permissions, available capabilities, activity and usage; exclude unrelated management/private fields.
- [ ] Scope identities by connection origin, pinned Host, workspace/team and bot. Validate bot-to-session ownership; never accept an arbitrary session ID supplied as a bot reference.
- [ ] Add SwiftUI/Compose Bots lists and details using existing connection/session navigation. Show plugin unavailable, incompatible, disconnected and another-Host-writer states distinctly.
- [ ] Support bounded pagination/refresh and part-aware history; restore the same selection and drafts after reconnect without silent destination changes.
- [ ] Show usage coverage and call purpose. Missing historical overhead remains unknown, not zero.

**Exit:** both native clients display the same fixture roster/history/activity and recover it after reconnect; browsing starts no run and changes no data.

### 2. Complete one persistent bot's daily workflow

- [ ] Add deliberate bot creation/configuration and sending through narrow operations. Preserve existing Host permission presets and exact-action tool approval requirements.
- [ ] Persist mutation command IDs before sending; implement atomic Host deduplication and outcome lookup. On uncertain success, reconcile or require an explicit new action instead of blind replay.
- [ ] Implement native questions and the first declarative card subset. Bind replies to authenticated identity, workspace, bot, actual session/part, pending card ID, revision and expiry; reject duplicates/stale answers.
- [ ] Keep current tool approvals separate. Subscribe to the exact bot session's durable tool-call evidence before enabling Allow/Deny.
- [ ] Extend the route allowlists for side questions only after capability negotiation; `btw` and `btw-cancel` are absent from the inspected [Host](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/packages/plugin/src/plugin-route-bridge.ts#L7-L39) and [Android](https://github.com/liguobao/ds-harness-remote/blob/9a60e783ec1ceaff6116b0462a2863f07f602a55/apps/android/src/services/bot-catalog.ts#L31-L37) operation enums.
- [ ] Add one bounded side question per bot, independent cancel/dismiss and visible usage. Tool-shaped model output must never execute; preserve the main run and its history.
- [ ] Verify Stop requested versus confirmed, late responses, a lost acknowledgement, two clients answering once, Host restart and phone relaunch.

**Exit:** start one task, answer its question, approve its exact tool action, ask a side question, stop and recover without duplicate execution or an answer entering the wrong conversation.

### 3. Add memory and long-task continuity

- [ ] Expose source-linked Host memory read/search first, followed by explicit save/edit/forget with revision conflicts and recoverable change history.
- [ ] Define bot/group/team sharing policy and opt-in automatic review. Never copy local chat/memory to the Host merely by selecting a bot.
- [ ] Reuse Host chat search across all parts, with stable session/event anchors and full-message navigation. Test English, Chinese, Mongolian, short queries, empty results and bounded pages.
- [ ] Integrate the existing context steward and handoff/checkpoint lifecycle; preserve unfinished user requirements and original history. Check actual model context capacity rather than inheriting a large unknown-model fallback.
- [ ] Test messages arriving during a part switch, an outstanding question/approval, failed summaries, unavailable index, corrupted memory and restart during persistence. Preserve readable history on failure.
- [ ] Account for memory review, summary, checkpoint and steward calls under the same task/Host admission limits as visible work.

**Exit:** a long task survives a context transition and restart; exact earlier decisions are retrievable by source; private or unshared memory never appears in another scope's prompts/results.

### 4. Add a small controlled team

- [ ] Introduce one coordinator and at most two specialists in the first fixture; choose models from the Host catalog with DeepSeek as the initial supported provider.
- [ ] Reuse group membership, isolated member sessions and handoff parent IDs. Add native mentions, explicit chat-reference sharing, task status and result drill-down.
- [ ] Enforce human-granted role/workspace/capability boundaries on the Host. A delegated run cannot elevate authority or widen data access.
- [ ] Implement durable mailbox/admission state, loop rejection, child-result reconciliation and cancellation propagation. A Host restart must not repeat a completed tool side effect.
- [ ] Add Host-wide bounds covering children, side questions and background model calls. Proposed test defaults: one active main run per bot, two model calls concurrently per Host, delegation depth two, four child tasks and six inter-bot handoffs per parent task; finite tool/deadline limits remain mandatory. Tune against measured workloads before use.
- [ ] Pause at a limit with an explicit explanation and deliberate continuation. Continuing does not silently reset aggregate usage. Show all member and auxiliary usage in the parent task.
- [ ] Expose attachment of existing approved capability packs; keep new MCP execution, installs and permission elevation as distinct Host-authorized operations.

**Exit:** coordinator delegates, receives a result once, and reports it; deliberate loop/failure fixtures stop predictably; stopping the parent prevents new child work and reconciles in-flight outcomes.

### 5. Add bounded automation and optional parity

- [ ] Start with one-shot scheduled tasks; then finite recurrence with explicit end/run limits, timezone/DST handling, deduplicated delivery and user-visible pause/cancel.
- [ ] Test task migration between bot parts for partial failure; an interruption between new-task creation and old-task removal must not produce two future executions.
- [ ] Add image/vision and search adapters only after the existing attachment/path limits and provider-transmission disclosures pass. Keep search backend visible and fallback opt-in.
- [ ] Extend cards with bounded native charts/calculators if needed; exclude arbitrary HTML/JavaScript initially and use text fallback for unknown schema types.
- [ ] Evaluate Host browser control, connectors and optional notifications as separate capabilities. Reuse existing Host services; do not copy browser cookies or create new cloud infrastructure for parity.

**Exit:** a bounded scheduled task runs once at its intended time, recovers without duplicates, reports usage and stops at its configured end; disabling Bot support prevents new work while retaining history.

### 6. Validate the integrated product

- [ ] Add shared DTO/card/memory/command fixtures and official Host journeys for every enabled phase; run relevant upstream tests against the pinned compatible runtime.
- [ ] Cover revoked devices, cross-workspace references, poisoned memory/search content, stale cards, duplicate/concurrent commands, oversized payloads, malformed revisions and usage-store failure.
- [ ] Obtain a fresh independent security/correctness review after implementation, then compile both native apps with their actual crypto SDKs using the authorized hosted route.
- [ ] Validate a real enrolled Host separately. Native rendering, signed storage, relaunch and real-provider evidence require an authorized route; the current no-device/no-simulator/no-weight-download constraints remain in force.
- [ ] Before any real provider or recurring work, verify the authorized allowance and effective provider-enforced maximum; application counters and token charts are not an invoice ceiling. Keep test runs scripted until that gate is met.
- [ ] Scan exact outgoing source for secrets before any later publication. Record passed, failed, blocked and not-run checks in the existing roadmap. Handle store preparation only when resumed by the user.

## First implementation assignment

Start with **phase 0 plus the phase 1 read-only slice**: one pinned DS Bot in the existing Host fixture, a minimal sanitized roster/current-session projection through the existing Remote bridge, and identical typed Swift/Kotlin decoding. Do not begin with team automation or a new server.

After that contract passes, Host integration, Apple UI and Android UI can proceed in parallel with separate file ownership. Memory/context work depends on stable bot/part identity; teams depend on durable admission and aggregate execution bounds; schedules depend on both.

The original assessment was planning only. Subsequent implementation and source
publication are recorded in the implementation brief. This does not establish
full Bot execution, a user-operated installation or a store release.
