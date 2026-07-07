# Quenderin — the roadmap

**Status:** v1, 2026-07-07. This is the ONE consolidated, prioritized roadmap. The other
planning docs remain the deep-dives it links to; when they disagree with this file, this
file wins (and should be updated deliberately, not drifted from).

**Mission (owner, 2026-07-05):** local autonomous computer usage — *you say what to do,
Quenderin operates the computer, with a local model as the brain and nothing leaving the
machine.* Local LLM chat is the foundation and the funnel; the governed autonomy layer is
the destination and the paid tier. Competitive frame: cloud computer-use agents (Claude
Cowork), beaten on privacy/trust/reversibility — never on raw model IQ.

Sources consolidated here: [PRODUCT.md](PRODUCT.md) · [AGENT_AUTONOMY_PLAN.md](AGENT_AUTONOMY_PLAN.md)
· [SHIP_READINESS.md](SHIP_READINESS.md) · [WINDOWS_LINUX_STRATEGY.md](WINDOWS_LINUX_STRATEGY.md)
· the public 4-stage story ([website/roadmap.html](../website/roadmap.html)) · audits under
[audits/](audits/).

---

## Where we actually are (honest snapshot, 2026-07-07)

| Track | State |
|---|---|
| **Mobile apps (iOS + Android)** — private offline chat + T0 pure-compute agent | **Software-complete and store-ready**; 295 Swift tests / 259 CoreVerify checks green; blocked ONLY on owner-gated store items (accounts, signing, console clicks, device numbers) |
| **Desktop agent (TS/Electron)** — the governed capability agent | **Works end-to-end today** via `quenderin do` (CLI): plan → preview → one approval → act → ledger → undo (even cross-session), ~400 TS tests. Capability library: fs.\*, app.\* (ADB), mac.\* (Calendar, Reminders, Notes, Mail-draft, Shortcuts, full-GUI `mac.ui.*`) |
| **Safety/governance spine** | Shipped on all three platforms: tiers T0–T4, blocklist (one canonical list, parity-enforced), consent, preview, per-run approval, append-only ledger, kill switch, dry-run, durable undo |
| **Cross-platform parity** | Machine-enforced (agent/safety/router/catalog parity scripts in CI); twin-drift audit batches 1–3 shipped — all P0/P1 drifts resolved |
| **Website / funnel** | quenderin.org live (privacy, roadmap, dev-log); in-app links all funnel there |
| **Honest weak spot** | GUI/action **grounding** — reliable action-selection by a small local model. The harness (guards, verification, undo) is how we compensate; this is the long-term technical frontier |

---

## Horizon 0 — Ship what's built *(owner-gated · target: next 2–4 weeks)*

The apps are done; the remaining work is accounts, clicks, and hardware — an agent cannot
do these. Full checklist with exact steps: [SHIP_READINESS.md](SHIP_READINESS.md).

1. Apple Developer + Play Console accounts; signing (keystore steps in [RELEASE.md](RELEASE.md)).
2. Console questionnaires: 17+/Mature rating, Apple EULA opt-in, Play Data-Safety
   ("no data collected"), iOS review notes; paste the privacy-policy URL.
3. Build the iOS xcframework + xcodegen target; add `jni/llama.cpp` for the real-inference APK.
4. Screenshots + store copy — **offline private assistant wording**, never "controls your phone".
5. Physical-device ground truth: tok/s + thermals on a real iPhone and Android phone
   (replaces the estimate tables).
6. Desktop prototype loose ends (if distributing it at all): live-verify the per-launch
   token; code-sign/notarize.

**Why first:** the free apps are the funnel and the credibility engine for everything below.
Every week unshipped is zero users compounding.

## Horizon 1 — Desktop agent v1: "trustworthy, not just capable" *(engineering · 1–2 months)*

Make the already-working governed agent a product someone else can use. Deep-dive:
[AGENT_AUTONOMY_PLAN.md](AGENT_AUTONOMY_PLAN.md) §7 (M0–M4 shipped; this is what remains).

**Platform decision (owner, 2026-07-07):** the macOS *product* is the native Swift app —
all Quenderin functionality on macOS ships there. The Electron/TS side keeps exactly three
jobs: (a) the R&D lab where capability classes are proven cheaply (headless tests, fast
iteration), (b) the `quenderin do` CLI (works today, dev-audience), (c) the future
Windows/Linux vehicle. Its GUI stays lab-grade — no further product polish. Distribution
consequence: full automation (Apple Events + Accessibility) is largely incompatible with
App Store sandboxing, so the autonomy tier ships as a **notarized direct-download Swift
app** (which also fits H2 — sell Pro direct from quenderin.org, no store cut); a MAS build
can stay the bounded free chat product.

1. **macOS-native agent surface in the Swift app** — the governance spine (tiers, gate →
   approve → run → ledger, workspace fs.\*, plan preview, undo) already exists natively in
   QuenderinKit; port the capability *library* from TS: `mac.*` (prefer native EventKit /
   AX APIs over osascript where possible), skill memory, durable undo journal, dry-run —
   plus the approval dialog and a Tasks pane in the Mac app. *(The Electron Tasks surface
   shipped 2026-07-07 remains the lab's reference implementation of this exact loop.)*
2. **Retire the legacy raw-action loop** — migrate `AgentService` to the governed
   `CapabilityAgent` per the Q-549 scoping analysis
   ([audits/2026-07-06-Q549-agent-governance-analysis.md](audits/2026-07-06-Q549-agent-governance-analysis.md));
   one agent, one governance path.
3. **Chore-class breadth** — grow the capability library where demos convert: files/organize
   (done), calendar/reminders/notes (done), Shortcuts (done), GUI-drive (done) → next:
   browser-adjacent chores via Shortcuts/AppleScript, batch file transforms, "collect →
   summarize → write report" pipelines.
4. **Reliability harness over weak models** — the loop guard + parse-recovery shipped;
   next: post-action verification everywhere (`verify()` beyond `mac.ui.tap`), retrieval of
   known-good action sequences, rate limits on bulk actions.
5. **Durable watch-and-resume** (the §4b "wait for replies" execution model) — design doc
   first; this is new architecture, not a capability.
6. **Android/mobile catch-up (parity debt):** Compose agent UI (attach/workspace/approval/
   ledger surfaces), Android PDF text extraction.

**Exit criterion:** a non-developer can install the desktop app, say "organize my Downloads
into folders by type and month", read the plan, click approve once, watch it happen, and
undo it — with zero terminal use.

## Horizon 2 — Monetization: open-core, autonomy is the paid tier *(product/business · starts alongside H1)*

Recorded direction (owner, 2026-07-04/05): chat + model library stay free and MIT; the
**paid Pro tier is the autonomy layer** — "an agent that uses your computer FOR you, and
nothing leaves the machine."

1. **Pick the vehicle** *(owner decision)*: paid Pro desktop app vs. license key vs. IAP;
   likely simple one-time or yearly license served from quenderin.org.
2. **Draw the free/paid line in code**: T0–T1 (chat, perception) free everywhere; T2+
   autonomy behind the Pro gate on desktop. Never ship autonomy free in store apps.
3. **Funnel discipline**: every in-app link → quenderin.org (standing rule); add a
   Pro page + changelog/dev-log cadence; the store apps' Settings link the desktop agent.
4. **Later:** org licensing for compliance-sensitive buyers (legal/medical/finance) — the
   "no AI middleman" pitch is strongest where cloud agents are prohibited.

## Horizon 3 — Widen the moat *(quarter+)*

- **T1 perception on mobile** — read-only, consented (attach-a-PDF already ships; camera/
  image description next). *Requires the PRODUCT.md revision the plan flags — owner sign-off.*
- **Windows/Linux** — per [WINDOWS_LINUX_STRATEGY.md](WINDOWS_LINUX_STRATEGY.md); the fs.\*
  half of the agent already runs off-macOS (`--workspace`), full parity needs a UI-automation
  surface per OS.
- **Opt-in connectors** (user's own OAuth to Google etc.) — a deliberate, opt-in departure
  from pure-local; never the default; design constraints in AGENT_AUTONOMY_PLAN §4b.
- **Grounding R&D** — evaluate each small-model generation against the GUI-driving suite;
  the moment a 4–8B grounds reliably, the "drive any app" story goes from demo to flagship.

---

## Standing engineering tracks (parallel, low-intensity)

- **Twin parity**: remaining P2/P3 seam-normalization batch (number rendering, rounding,
  digit classes, Unicode length units) + the audit's 2 never-scored subsystems
  ([audits/2026-07-06-twin-drift-audit.md](audits/2026-07-06-twin-drift-audit.md) items 12–13, data gaps).
- **Backlog burn-down**: 25 quick wins (mostly a11y) in
  [audits/2026-06-27-improvement-backlog.md](audits/2026-06-27-improvement-backlog.md).
- **Journal + parity discipline** (BUG_JOURNAL.md, parity vectors) — every fix, same commit.

## Decision queue (owner input needed — nothing below proceeds without it)

| # | Decision | Blocks |
|---|---|---|
| 1 | Create store accounts / do the console items (H0 §1–2) | the entire mobile launch |
| 2 | Monetization vehicle (Pro app vs license vs IAP) | H2 §2 gating work |
| 3 | PRODUCT.md revision: allow T1 perception in store apps | H3 mobile perception |
| 4 | Twin-drift item 6: persist-mid-stream semantics (Q-324/325 by-design area) | that parity fix |
| 5 | Twin-drift item 14: ConversationStore salvage format + `modelID` on Android | that parity fix |

## Anti-goals (permanent fences — restated so the roadmap can't drift)

No cloud calls from our code · no accounts/telemetry · no "run arbitrary script" capability ·
no free-roaming mobile automation (store apps stay ≤T1) · no bulk-outreach marketing ·
no benchmark race against frontier models · T4 (irreversible/sensitive) never autonomous.
