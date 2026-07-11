import {
    Capability, CapabilityTier, ConsentStore, AuditLedger, ActionPreview, RunSession,
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
        /** Dry run: execute reads (to ground the plan in real state) but NEVER perform a mutating
         *  action — show its preview and move on. "See exactly what it would do, touching nothing" —
         *  an exact, side-effect-free, LOCAL preview a cloud agent can't offer. */
        private readonly dryRun = false,
    ) { }

    /** Successful mutating actions since the last bulk re-confirmation this run. */
    private mutationsThisRun = 0;

    /** r-uc #12: did the LAST execute()/executePlan() actually RUN a capability (vs refuse/block/
     *  decline/error/dry-run)? The agent loop reads this so it only credits SUCCESSFUL actions toward
     *  its progress/zero-action guard and its skill memory — a refused call is not "progress". Valid
     *  only immediately after the awaited call (the loop is sequential per run). */
    lastExecuted = false;

    /** The goal of the current run — stamped onto every ledger entry so `history` can group a task's
     *  actions together (a structured local audit, vs a cloud agent's flat chat log). */
    private runGoal?: string;

    /** Tell the runner what task the upcoming actions serve (the agent sets this at run start). */
    setRunGoal(goal: string | undefined): void {
        this.runGoal = goal?.trim() || undefined;
        // Q-384: the bulk-brake window is PER-RUN. This is the run-start hook (desktopAgent calls it
        // right before agent.run), so a fresh task must NOT inherit the previous run's mutation count —
        // otherwise run 2's brake fires after far fewer than `bulkThreshold` of its OWN changes.
        this.mutationsThisRun = 0;
    }

    private log(cap: Capability, input: string, decision: string, outcome?: string): void {
        this.ledger.append({ timestampMs: this.now(), capability: cap.name, tier: cap.tier, input, decision, outcome, goal: this.runGoal });
    }

    /** Advisory post-condition check: annotate the observation + ledger an 'unverified' note when
     *  a capability's verify() reports the action didn't visibly take. Never undoes anything (it
     *  already ran) — this is "the agent checks its own work", not a rollback. */
    private async annotateWithVerification(capability: Capability, input: string, result: string): Promise<string> {
        if (!capability.verify) return result;
        try {
            const v = await capability.verify(input);
            if (!v.ok) {
                this.log(capability, input, 'unverified', v.detail);
                return `${result}\n(Couldn't confirm it worked: ${v.detail})`;
            }
        } catch {
            // Verification is best-effort; a failure to check doesn't fail the action.
        }
        return result;
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
        this.lastExecuted = false;   // r-uc #12: assume not-run until a capability actually runs below
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
        // 3b. Dry run: a mutating action is SHOWN, never done — no approval, no execution, no undo.
        if (this.dryRun && preview.mutates) {
            this.log(capability, input, 'dryRun', preview.summary);
            return `[dry run] Would: ${preview.summary} (nothing was changed)`;
        }
        // 4. Per-run approval when it mutates. Fail closed without an approver.
        if (preview.mutates) {
            if (!this.approve) {
                this.log(capability, input, 'needsApproval');
                return 'This action changes things and needs your per-run approval, which this surface can\'t ask for. Not done.';
            }
            if (!await this.approve({ ...preview, tier: capability.tier })) {
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
            this.lastExecuted = true;   // r-uc #12: a capability actually ran → real progress
            this.log(capability, input, 'allowed', result);
            if (preview.mutates) {
                this.session?.record(capability, input);
                this.mutationsThisRun++;
            }
            return await this.annotateWithVerification(capability, input, result);
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
        this.lastExecuted = false;   // r-uc #12: flips true only once a step actually runs below
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
                // r-uc #17: ledger the preview failure like execute() does — a step that couldn't even
                // be previewed is an audit event, not a silent return (the whole plan aborts here).
                this.log(item.capability, item.input, 'error', `preview failed: ${String(e)}`);
                return `Couldn't preview step ${previews.length + 1} (${item.capability.name}): ${String(e)}. Nothing was done.`;
            }
        }
        // ── Dry run: if any step mutates, show the WHOLE plan and stop — nothing runs. Every step is
        //    ledgered 'dryRun', including reads: in preview-only mode NOTHING executed, so logging a
        //    read as 'allowed' (with a made-up outcome) would misrepresent the audit.
        if (this.dryRun && previews.some(p => p.mutates)) {
            const numbered = previews.map((p, i) => `${i + 1}. ${p.summary}`).join('\n');
            items.forEach((item, i) => this.log(item.capability, item.input, 'dryRun', previews[i].summary));
            return `[dry run] The agent would run this plan (nothing was changed):\n${numbered}`;
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
            // The plan's tier is its most dangerous step — so a plan containing a T3 app action
            // still prompts under a tier-aware auto-approver, even if the rest is reversible.
            const planTier = items.reduce<number>((t, item) => Math.max(t, item.capability.tier), 0) as CapabilityTier;
            const combined: ActionPreview = { summary: `${banner}The agent proposes this plan:\n${numbered}`, mutates: true, tier: planTier };
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
            // Q-551 (by design): NO per-step bulk re-ask inside a plan. Unlike the single-action path —
            // where each change is unpreviewed, so the brake re-asks after N — a plan is FULLY previewed
            // up front (every step's summary) with a loud "⚠️ makes N changes" banner and taken under ONE
            // informed approval. That IS the bulk consent for the batch; a mid-plan re-ask on a plan the
            // user just reviewed in full would be redundant friction. The plan's changes still increment
            // mutationsThisRun, so the run's brake fires on the NEXT single action if the run keeps going.
            try {
                const result = await item.capability.run(item.input);
                this.lastExecuted = true;   // r-uc #12: at least one plan step actually ran
                this.log(item.capability, item.input, 'allowed', result);
                if (previews[i].mutates) {
                    this.session?.record(item.capability, item.input);
                    this.mutationsThisRun++;   // a plan's changes count toward the run's bulk brake too
                }
                results.push(`${i + 1}. ${await this.annotateWithVerification(item.capability, item.input, result)}`);
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
