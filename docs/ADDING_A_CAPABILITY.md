# Adding a capability

The computer-use agent is a **growing library of governed capabilities**. The whole mission —
"anything possible on your machine" — is reached one capability at a time, and the safety spine
never bends to add one. This guide shows how to add yours.

If you only read one thing: a capability **declares its blast radius**, and the `CapabilityRunner`
gates on that declaration — *before* your code runs — instead of trusting your code to behave. Get
the declaration right and the governance (consent, preview, approval, ledger, undo) is free.

See also: [AGENT_AUTONOMY_PLAN.md](AGENT_AUTONOMY_PLAN.md) (the why), and the desktop implementation
in [`src/services/capability/`](../src/services/capability/).

## The mental model

Every turn, a local model proposes a tool call. The runner puts it through one fixed gate, with no
path around it:

```
blocklist → consent → preview(plan) → per-run approval (if it mutates) → run → ledger → verify
```

You write a `Capability`; the runner does the rest.

## The tiers (pick honestly — the gate keys off this)

| Tier | Meaning | Gating |
|---|---|---|
| **T0 PureCompute** | no side effects (math, text transforms) | none |
| **T1 ReadOnly** | reads something the user pointed at; nothing changes | standing consent |
| **T2 ReversibleWrite** | a change that's undoable / low-stakes | consent + **per-run approval** |
| **T3 AppAction** | drives an app / fills (not submits) a form | consent + per-run approval |
| **T4 Irreversible** | permanent delete, submit, send | **never autonomous** |

Declare the *most dangerous thing your capability can do*, not the common case. `blastRadius.kind`
must be `write`/`irreversible` for anything that mutates — that's what triggers approval.

## The `Capability` interface

```ts
export class FooCapability implements Capability {
  readonly name = 'foo.bar';                 // stable id the planner emits
  readonly purpose = 'One line the model sees. Say the INPUT FORMAT here.';
  readonly tier = CapabilityTier.ReversibleWrite;
  readonly blastRadius: BlastRadius = { kind: 'write', resource: 'what it touches' };

  async plan(input: string): Promise<ActionPreview> {
    // Side-effect-FREE. Describe what run() WOULD do. `mutates` gates approval.
    return { summary: `Would do X with "${input}".`, mutates: true };
  }
  async run(input: string): Promise<string> {
    // The runner guarantees blocklist + consent + approval already passed. Return a human sentence.
  }
  async undo?(input: string): Promise<string> { /* reverse a just-run action, same input */ }
  async verify?(input: string): Promise<{ ok: boolean; detail: string }> { /* did it take? */ }
}
```

- **`undo`** is what makes "undo this task" (and cross-session `quenderin undo`) work — implement it
  whenever the action can genuinely reverse itself. A created thing deletes; a tap can't un-tap.
- **`verify`** is the reliability lever for a weak local model: check the post-condition and say so
  honestly ("couldn't confirm…") rather than assume success. Advisory, never a rollback.

## Rule 1 — the seam pattern (this is how you stay testable)

If your capability touches the outside world (macOS, a device, the network), do **not** call it
directly. Put a thin **seam** interface in front of it, with a production implementation and a
**fake** for tests. Then the capability *logic* — input parsing, label resolution, the blocklist
re-check, `verify` — is fully unit-testable headless; only the production bridge is production-only,
exactly like every other capability. (Don't ever call a capability "unverifiable" — see
[the note below](#dont-defer-native-work-as-unverifiable).) The macOS GUI seam
[`MacUi`](../src/services/capability/macUi.ts) ↔ its capabilities
[`macUiCapabilities.ts`](../src/services/capability/macUiCapabilities.ts) ↔ the fake in
[`tests/mac-ui.test.ts`](../tests/mac-ui.test.ts) is the canonical example.

## Rule 2 — never a "run arbitrary X" hole

Reach comes from a *growing library of typed, bounded* capabilities — never one capability that runs
arbitrary shell/AppleScript/SQL. `mac.shortcuts.run` invokes a shortcut the user *already built*, by
name; it can't author one. If you're tempted to add an escape hatch, add ten specific capabilities
instead.

## Rule 3 — the model names what it can see; escape everything

- Act **by visible label**, never by a coordinate or path the model invents (`app.tap`/`mac.ui.tap`
  resolve a real on-screen element; `fs.move` takes a plain name via `safeName`, never a path).
- **Defense in depth:** re-check the *resolved* target against the blocklist inside `run()` — an
  element labeled "OK" that resolves to a payment button must still be refused.
- Every user/model-controlled value going into a shell/AppleScript template **must** be escaped
  (`escapeAppleScriptString`, `execFile` not `exec`). No exceptions.

## Wiring it in

1. Add the class to the toolkit function for its family (`macCapabilities()`, `fileCapabilities()`,
   `macUiCapabilities()`, …).
2. If it needs a new seam, add the dep to `GovernedAgentDeps` in
   [`desktopAgent.ts`](../src/services/capability/desktopAgent.ts) and spread it into `capabilities`.
3. Grant its consent where the CLI wires the run ([`src/index.ts`](../src/index.ts) `do` command).

## Testing (required)

- Unit-test the logic against a **fake seam**: the happy path, the refusals (bad input, ambiguous,
  blocklisted), `undo`, and `verify`. Put it in the family's test file.
- Confirm it's **discoverable**: it appears in `quenderin capabilities` (that's driven by the real
  toolkit, so a registration miss shows up in [`tests/catalog.test.ts`](../tests/catalog.test.ts)).
- Run `npm run typecheck:src && npm run lint:src && npm test`.

## Cross-platform + parity

The desktop TS spine has native twins (Swift `QuenderinKit`, Kotlin `quenderin-core`). If your change
touches **shared agent logic** (the decision parser, the safety blocklist), it's machine-enforced
against drift — update all platforms and the parity vectors (`scripts/check_*_parity.py` fail CI
otherwise). A desktop-only capability (most `mac.*`, `fs.*`) needs no twin.

## <a name="dont-defer-native-work-as-unverifiable"></a>Don't defer native work as "unverifiable"

The seam+fake pattern means the *capability logic* is always testable, even for GUI/AppleScript/ADB
work — only the thin production bridge runs on a real machine (the same production-only surface every
`mac.*` already ships). Build the seam, unit-test the logic against the fake, write a defensible
production bridge, ship. The bridge is exercised on the user's Mac like all the others.
