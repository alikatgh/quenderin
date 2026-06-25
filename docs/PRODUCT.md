# Product identity & positioning — the decision

> One page. The decision, not a survey. If a feature or a piece of store copy contradicts this,
> the feature/copy is wrong. Resolves the "product-identity muddle" and "no wedge" gaps.

## The decision (one line)

**Quenderin Mobile (iOS + Android) is a private, offline, on-device AI chat assistant** — not an
autonomous device-controller. The desktop Electron app is a separate research/dev prototype and is
**not** the shipped product.

## Two products, deliberately split

| | **Quenderin Mobile** (the product) | **Quenderin Desktop** (Electron prototype) |
|---|---|---|
| What it is | A private chat assistant + a SAFE pure-compute tool agent (math, unit/date conversion) | A research tool that can *drive* an Android device — read the screen, click, type |
| Runs | on the phone, via llama.cpp (Swift/JNI) | on a laptop, controlling a connected phone via ADB |
| Ships to | App Store / Play Store | nowhere — dev-only |
| The "agent" | bounded to **pure-compute tools** (`CalculatorTool`, `UnitConverterTool`, `DateCalcTool`) — no side effects, no device access | full device automation |

**Why the split is load-bearing:** an autonomous device-controller on mobile means an Accessibility
Service that clicks/types for the user — a store-review red flag (Google's automation/accessibility
policies, Apple's near-total ban) **and** a security liability (a prompt-injected model driving your
phone). The mobile apps already avoid this (their agent only does arithmetic/units). This doc makes
that permanent: **the device-agent stays desktop-only and is never ported to the store apps.**

## The wedge — who it's for, and the one job

Do **not** position this as a general ChatGPT replacement. On raw answer quality a 1–4B on-device
model loses to a frontier cloud model, and that gap widens over time — so don't compete on the axis
where we lose. Compete where cloud **structurally cannot follow**:

**"AI that works with no signal and never leaves your phone."**

Two hero users where that's not a nice-to-have but the whole point:

1. **No-connectivity** — travel (planes, abroad without a data plan), rural / off-grid, field work.
   Cloud AI is simply *unavailable*. We're the only option, not the cheaper one.
2. **Privacy-required** — journaling, personal/health/legal notes, anything the user will not send to
   a server. "Nothing you type leaves your phone" is a guarantee a cloud product cannot make.

Plus a third, softer wedge: **free, no account, no subscription** — for cost-sensitive users,
education, and regions where paid AI is gated.

**The quality-ceiling reframe:** when the axis is *offline + private + free*, "the model is smaller
than GPT-5" stops being the comparison. A 1–4B model that answers a travel question on a plane, or
helps draft a private journal entry, wins by *existing* there. The product's job is to make a small
model *feel good enough for that job* — which is exactly what the engineering does (right-sized model
per device, snappy chat via KV reuse, honest expectations, easy model-swapping as small models improve).

## What's in / out of the mobile product

**In** (shipped, on-thesis): offline chat · device-aware model selection + download + integrity ·
conversation history + **export/share** · model **storage management** · the safe pure-tool agent ·
settings + model switching · on-device content-safety + report affordance · the hardware-adaptation
layer (jetsam-aware sizing, thermal governors, KV-cache reuse).

**Out** (deliberately not on mobile): device automation / screen control · any cloud call · accounts ·
telemetry · anything that breaks "nothing you type leaves your phone."

## What this unblocks

- **Store copy & screenshots** describe the *offline private assistant* — never "controls your phone"
  (see `docs/SHIP_READINESS.md` §D).
- **Feature triage** has a test: does it serve "private, offline, on-device chat"? If not, it's desktop
  or it's out.
- **Marketing/landing** leads with the wedge (offline + private), not a benchmark race it would lose.
