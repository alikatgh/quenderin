/**
 * The autonomy layer's core abstraction, TypeScript twin of the Swift/Kotlin `Capability`
 * (AGENT_AUTONOMY_PLAN §6). A Capability DECLARES its blast radius so the runner can gate on the
 * declaration — before ever calling run — instead of trusting the tool to behave. This is the
 * governance layer the desktop lacked: it had ADB muscle (AndroidProvider) but no
 * consent/preview/approval/ledger discipline. Now device-driving runs behind the same spine as
 * the native apps' file capabilities.
 */

/** The risk tier the agent climbs one rung at a time (§4). Higher = more dangerous, more gated. */
export enum CapabilityTier {
    PureCompute = 0,     // T0 — no side effects
    ReadOnly = 1,        // T1 — reads a resource the user pointed at; nothing changed
    ReversibleWrite = 2, // T2 — changes that can be undone / are low-stakes and reversible
    AppAction = 3,       // T3 — drives an app / fills (not submits) a form
    Irreversible = 4,    // T4 — permanent delete, submit, send; NEVER autonomous
}

export type BlastRadius =
    | { kind: 'none' }
    | { kind: 'read'; resource: string }
    | { kind: 'write'; resource: string }
    | { kind: 'irreversible'; resource: string };

export function mutates(b: BlastRadius): boolean {
    return b.kind === 'write' || b.kind === 'irreversible';
}

/** A side-effect-free description of what running WOULD do (Shortcuts "read before you run"). */
export interface ActionPreview {
    summary: string;
    mutates: boolean;
}

/**
 * An action the agent can invoke that declares its risk. Conforming tools get gated by the
 * CapabilityRunner: blocklist → consent → preview → (per-run approval if mutating) → run → ledger.
 */
export interface Capability {
    readonly name: string;         // stable id the planner emits, e.g. "app.tap"
    readonly purpose: string;      // one line the planner sees
    readonly tier: CapabilityTier;
    readonly blastRadius: BlastRadius;
    /** Preview `run(input)` WITHOUT performing the side effect. Required for T2+. */
    plan(input: string): Promise<ActionPreview>;
    /** Execute. The runner guarantees blocklist + consent + approval already passed. */
    run(input: string): Promise<string>;
    /**
     * OPTIONAL reversal of a just-run action with the SAME input — the "undo this whole task"
     * building block. A capability implements it only if it can genuinely reverse itself
     * (a created reminder/note deletes; a tap can't un-tap, so it has no undo). The runner
     * records undoable successful actions into a RunSession; the user's Undo replays them LIFO.
     * User-initiated, so it does NOT pass back through the blocklist gate (like the file
     * UndoJournal). Returns a human sentence.
     */
    undo?(input: string): Promise<string>;

    /**
     * OPTIONAL post-condition check — "did it actually work?" — run right after `run` succeeds.
     * The reliability lever that attacks our honest weakness: a weak local model makes clumsy
     * actions (a GUI tap that silently doesn't register), and a VERIFYING agent notices and says
     * so, where a naive cloud agent just assumes success. Advisory, not a gate: a false `ok`
     * annotates the observation ("couldn't confirm…") and ledgers 'unverified'; it never
     * un-does the action (it already happened). A throw is treated as "couldn't verify".
     */
    verify?(input: string): Promise<{ ok: boolean; detail: string }>;
}

/** Everything above T0 requires the user's standing grant. */
export function requiresConsent(c: Capability): boolean {
    return c.tier > CapabilityTier.PureCompute;
}

// ─── Consent (standing grants, set BY THE USER — never from model output) ───────────────────

export interface ConsentStore {
    isGranted(capabilityId: string): boolean;
    setGranted(capabilityId: string, granted: boolean): void;
}

export class InMemoryConsentStore implements ConsentStore {
    private readonly granted = new Set<string>();
    isGranted(id: string): boolean { return this.granted.has(id); }
    setGranted(id: string, granted: boolean): void {
        if (granted) this.granted.add(id); else this.granted.delete(id);
    }
}

// ─── Audit ledger (the flight recorder — every invocation, incl. refusals) ──────────────────

export interface AuditEntry {
    timestampMs: number;
    capability: string;
    tier: number;
    input: string;   // truncated
    decision: string; // "allowed" | "blocked(<kw>)" | "needsConsent" | "needsApproval" | "declined" | "error"
    outcome?: string;  // truncated result/error when it ran; undefined when refused
}

export interface AuditLedger {
    append(entry: AuditEntry): void;
    entries(): AuditEntry[];
}

export class InMemoryAuditLedger implements AuditLedger {
    private readonly stored: AuditEntry[] = [];
    append(entry: AuditEntry): void {
        this.stored.push({ ...entry, input: entry.input.slice(0, 200), outcome: entry.outcome?.slice(0, 200) });
    }
    entries(): AuditEntry[] { return [...this.stored]; }
}

// ─── Session undo (the "undo this whole task" record) ───────────────────────────────────────

/**
 * Records the undoable actions of one agent run so the user can reverse the ENTIRE task with one
 * click — the pair to the kill switch (stop) and the ledger (review). Only successful mutating
 * actions whose capability declares `undo` are recorded; reversal replays them LIFO (last done,
 * first undone), so intermediate state is consistent. A cloud agent can't offer transactional
 * undo of local changes; this is a local-agent trust superpower.
 */
export class RunSession {
    private readonly done: Array<{ capability: Capability; input: string }> = [];

    /** Called by the runner after a successful mutating action that CAN be undone. */
    record(capability: Capability, input: string): void {
        if (capability.undo) this.done.push({ capability, input });
    }

    /** How many actions this session could undo. */
    get undoableCount(): number { return this.done.length; }

    /** Reverse everything this run did, newest first. Best-effort: a failed reversal is reported
     *  but doesn't stop the rest (the user wants as much rolled back as possible). */
    async undoAll(): Promise<string> {
        if (this.done.length === 0) return 'Nothing to undo from this task.';
        const lines: string[] = [];
        while (this.done.length > 0) {
            const { capability, input } = this.done.pop()!;
            try {
                lines.push(await capability.undo!(input));
            } catch (e) {
                lines.push(`Couldn't undo ${capability.name}(${input}): ${String(e)}`);
            }
        }
        return lines.join('\n');
    }
}
