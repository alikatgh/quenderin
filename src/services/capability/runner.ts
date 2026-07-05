import {
    Capability, ConsentStore, AuditLedger, ActionPreview, RunSession,
    InMemoryConsentStore, InMemoryAuditLedger, requiresConsent, mutates,
} from './capability.js';
import { matchedBlockedKeyword } from './safety.js';

/** Per-run approval for MUTATING capabilities — shown the preview, resolves yes/no. */
export type Approver = (preview: ActionPreview) => Promise<boolean>;

/**
 * The enforcement point (AGENT_AUTONOMY_PLAN §6), TypeScript twin of Swift/Kotlin
 * `CapabilityRunner`: every capability invocation goes gate → (refuse | run) → ledger, with NO
 * path around it. A mutating action additionally needs the user's yes for THIS run — a standing
 * consent grant isn't enough. FAIL-CLOSED: no approver wired ⇒ every mutating action is refused.
 */
export class CapabilityRunner {
    constructor(
        private readonly consent: ConsentStore = new InMemoryConsentStore(),
        private readonly ledger: AuditLedger = new InMemoryAuditLedger(),
        /** Undefined ⇒ mutating actions are refused (fail closed). */
        private readonly approve?: Approver,
        private readonly now: () => number = () => Date.now(),
        /** When provided, successful undoable mutating actions are recorded here so the whole
         *  task can be reversed with one click ("undo this task" — the pair to the kill switch). */
        private readonly session?: RunSession,
        /** After this many changes in one run, the next change re-asks the user ("the agent has
         *  made N changes — keep going?"). The runaway/bulk brake: a stuck loop or a 500-message
         *  outreach hits a wall. 0 disables. A cloud agent runs 500 steps and bills you; ours pauses. */
        private readonly bulkThreshold = 20,
    ) { }

    /** Successful mutating actions since the last bulk re-confirmation this run. */
    private mutationsThisRun = 0;

    private log(cap: Capability, input: string, decision: string, outcome?: string): void {
        this.ledger.append({ timestampMs: this.now(), capability: cap.name, tier: cap.tier, input, decision, outcome });
    }

    /** The bulk brake: true if it's safe to make another change; asks the user once the run has
     *  crossed the threshold, resetting the window on a yes. Fail-closed (no approver ⇒ stop). */
    private async passesBulkGuard(): Promise<boolean> {
        if (this.bulkThreshold <= 0 || this.mutationsThisRun < this.bulkThreshold) return true;
        if (!this.approve) return false;
        const ok = await this.approve({
            summary: `⚠️ The agent has already made ${this.mutationsThisRun} changes in this task. Approve continuing?`,
            mutates: true,
        });
        if (ok) this.mutationsThisRun = 0;   // start a fresh window
        return ok;
    }

    /**
     * Run a single capability through the full gate. Returns the observation for the agent loop.
     * `signal` is the KILL SWITCH: if it's already aborted the action is refused before running —
     * the trust superpower a LOCAL agent can offer that a cloud one can't (you halt execution on
     * your own machine, instantly, no round-trip).
     */
    async execute(capability: Capability, input: string, signal?: AbortSignal): Promise<string> {
        if (signal?.aborted) {
            this.log(capability, input, 'cancelled');
            return 'Stopped — you halted the agent.';
        }
        // 1. Blocklist — refused regardless of tier or consent.
        const hit = matchedBlockedKeyword(input);
        if (hit) {
            this.log(capability, input, `blocked(${hit})`);
            return `Refused: touches a blocked action ('${hit}').`;
        }
        // 2. Standing consent for anything above pure compute.
        if (requiresConsent(capability) && !this.consent.isGranted(capability.name)) {
            this.log(capability, input, 'needsConsent');
            return `Needs your permission first: "${capability.name}" isn't granted in Settings.`;
        }
        // 3. Preview (side-effect-free).
        let preview: ActionPreview;
        try {
            preview = await capability.plan(input);
        } catch (e) {
            this.log(capability, input, 'error', `preview failed: ${String(e)}`);
            return `Couldn't preview ${capability.name}: ${String(e)}`;
        }
        // 4. Per-run approval when it mutates. Fail closed without an approver.
        if (preview.mutates) {
            if (!this.approve) {
                this.log(capability, input, 'needsApproval');
                return 'This action changes things and needs your per-run approval, which this surface can\'t ask for. Not done.';
            }
            if (!await this.approve(preview)) {
                this.log(capability, input, 'declined');
                return `You declined: ${preview.summary} Nothing was changed.`;
            }
            // 4b. The runaway/bulk brake — after N changes this run, re-ask before continuing.
            if (!await this.passesBulkGuard()) {
                this.log(capability, input, 'bulkPaused');
                return `Paused — the agent has made ${this.bulkThreshold}+ changes this task and you didn't approve continuing. Nothing more was done.`;
            }
        }
        // 5. Execute.
        try {
            const result = await capability.run(input);
            this.log(capability, input, 'allowed', result);
            if (preview.mutates) {
                this.session?.record(capability, input);
                this.mutationsThisRun++;
            }
            return result;
        } catch (e) {
            this.log(capability, input, 'error', String(e));
            return `Tool error: ${String(e)}`;
        }
    }

    /**
     * Execute a multi-step PLAN with ONE aggregate approval (the Cowork UX). Gate-atomic: every
     * step is blocklist- and consent-checked and previewed BEFORE anything runs — one bad step
     * refuses the whole plan without ever reaching approval. One approval when anything mutates
     * (fail-closed). Execution is sequential and each step is individually ledgered; a failing
     * step stops the remainder honestly.
     */
    async executePlan(items: Array<{ capability: Capability; input: string }>, signal?: AbortSignal): Promise<string> {
        if (signal?.aborted) return 'Stopped — you halted the agent before the plan ran.';
        const previews: ActionPreview[] = [];
        // ── Pre-flight.
        for (const item of items) {
            const hit = matchedBlockedKeyword(item.input);
            if (hit) {
                this.log(item.capability, item.input, `blocked(${hit})`);
                return `Refused: step ${previews.length + 1} touches a blocked action ('${hit}'). Nothing was done.`;
            }
            if (requiresConsent(item.capability) && !this.consent.isGranted(item.capability.name)) {
                this.log(item.capability, item.input, 'needsConsent');
                return `Needs your permission first: "${item.capability.name}" isn't granted in Settings. Nothing was done.`;
            }
            try {
                previews.push(await item.capability.plan(item.input));
            } catch (e) {
                return `Couldn't preview step ${previews.length + 1} (${item.capability.name}): ${String(e)}. Nothing was done.`;
            }
        }
        // ── One aggregate approval when anything writes.
        if (previews.some(p => p.mutates)) {
            const numbered = previews.map((p, i) => `${i + 1}. ${p.summary}`).join('\n');
            // A big batch is where a rubber-stamped preview hides bulk outreach or a runaway — say
            // it loud, at the top, so the count is the first thing the user sees.
            const changeCount = previews.filter(p => p.mutates).length;
            const banner = this.bulkThreshold > 0 && changeCount > this.bulkThreshold
                ? `⚠️ This plan makes ${changeCount} changes — review carefully.\n`
                : '';
            const combined: ActionPreview = { summary: `${banner}The agent proposes this plan:\n${numbered}`, mutates: true };
            if (!this.approve) {
                items.forEach(item => this.log(item.capability, item.input, 'needsApproval'));
                return 'This plan changes things and needs your approval, which this surface can\'t ask for. Nothing was done.';
            }
            if (!await this.approve(combined)) {
                items.forEach(item => this.log(item.capability, item.input, 'declined'));
                return 'You declined the plan. Nothing was changed.';
            }
        }
        // ── Execute sequentially; a failure OR the kill switch stops the remainder honestly.
        const results: string[] = [];
        for (let i = 0; i < items.length; i++) {
            const item = items[i];
            // The kill switch is honored BETWEEN steps: an approved plan you change your mind
            // about halts here, mid-task, with the already-done steps still ledgered + undoable.
            if (signal?.aborted) {
                this.log(item.capability, item.input, 'cancelled');
                results.push(`Stopped by you after step ${i} of ${items.length}. The remaining steps did not run.`);
                return results.join('\n');
            }
            try {
                const result = await item.capability.run(item.input);
                this.log(item.capability, item.input, 'allowed', result);
                if (previews[i].mutates) {
                    this.session?.record(item.capability, item.input);
                    this.mutationsThisRun++;   // a plan's changes count toward the run's bulk brake too
                }
                results.push(`${i + 1}. ${result}`);
            } catch (e) {
                this.log(item.capability, item.input, 'error', String(e));
                results.push(`${i + 1}. Failed: ${String(e)}`);
                results.push(`Stopped after step ${i + 1} of ${items.length}.`);
                break;
            }
        }
        return results.join('\n');
    }
}

// Re-export the accidental blast-radius helper users of the runner may want.
export { mutates };
