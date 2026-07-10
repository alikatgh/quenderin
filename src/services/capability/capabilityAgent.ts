import { Capability } from './capability.js';
import { CapabilityRunner } from './runner.js';
import { SkillMemory } from './skillMemory.js';
import { looksLikeComputerTask } from './actionIntent.js';
import { firstJsonObject } from '../../utils/json.js';

/**
 * The GOVERNED agent loop (desktop) — the TypeScript twin of the native `AgentLoop`, but
 * operating over `Capability`s through the `CapabilityRunner` instead of raw device actions.
 * This is the path that will ship: a local model proposes a capability call, a plan, or an
 * answer; everything mutating goes through blocklist → consent → per-run approval → ledger.
 *
 * Distinct from the legacy `AgentService` raw-action research loop (screenshot → click x,y),
 * which stays as the testbed. Decoupled from the LLM via a `Planner` seam so it's fully
 * testable with a scripted planner + a fake device.
 */
export type Planner = (prompt: string) => Promise<string>;

export interface AgentResult {
    answer: string | null;
    steps: string[];   // one observation line per executed step
    halt: 'answered' | 'maxSteps' | 'planError' | 'cancelled' | 'stalled';
}

type Decision =
    | { kind: 'tool'; name: string; input: string }
    | { kind: 'plan'; calls: Array<{ name: string; input: string }> }
    | { kind: 'answer'; text: string };

export class CapabilityAgent {
    private readonly byName: Map<string, Capability>;

    constructor(
        private readonly planner: Planner,
        private readonly capabilities: Capability[],
        private readonly runner: CapabilityRunner,
        private readonly maxSteps = 8,
        /** Optional skill memory: primes the model with proven sequences for similar past goals,
         *  and records this run's sequence if it succeeds. The reliability compounding loop. */
        private readonly memory?: SkillMemory,
        /** Opt-in "think, then decide" (twin of the native AgentLoop deliberation pass): when
         *  `deliberate()` is true AND a `think` planner is provided, the model reasons — UNCONSTRAINED,
         *  with a thinking budget — before the decision decode, and the reasoning is woven into the
         *  transcript as a closed <think> block the decision then sees. Off unless both are wired.
         *  A separate planner (not `planner`) because the decision decode is grammar/no-think while the
         *  think pass must be free to reason. */
        private readonly think?: Planner,
        private readonly deliberate: () => boolean = () => false,
    ) {
        this.byName = new Map(capabilities.map(c => [c.name, c]));
    }

    async run(goal: string, signal?: AbortSignal, onStep?: (line: string) => void): Promise<AgentResult> {
        const steps: string[] = [];
        // Record a step and stream it live — the CLI prints each as it happens (a 30-step task
        // shouldn't run in silence; watching it work is how you Ctrl+C the moment you see a wrong turn).
        const emit = (line: string) => { steps.push(line); onStep?.(line); };
        const usedTools: string[] = [];   // capability names this run drove (progress + zero-action guard)
        const usedSteps: Array<{ tool: string; input: string }> = []; // full sequence for skill memory
        let transcript = this.preamble(goal);
        // Loop guard: a weak local model's #1 failure is getting stuck re-emitting the SAME action.
        // We nudge once (feeding back the prior result), then halt 'stalled' rather than burn every
        // step making no progress — the graceful-failure that a big cloud model rarely needs but a
        // small local one does. `prevSig` is the last EXECUTED action's signature; `stall` counts
        // consecutive repeats of it.
        let prevSig: string | null = null;
        let lastObs = '';
        let stall = 0;
        // Parse-failure recovery: a weak local model's #2 failure (after looping) is malformed
        // structured output — a stray word, a trailing comma. Rather than kill the whole run on one
        // slip (a big cloud model rarely slips; a small local one does), feed the contract back and
        // let it retry, halting only if it can't produce valid JSON across consecutive tries.
        let parseFailures = 0;
        // Zero-action guard (twin of the native AgentLoop, previously only on iOS/Android): the model
        // answers a bare "Done" with an EMPTY run log. For a goal that reads as a computer task
        // (ActionIntent), an answer with zero capability calls gets ONE corrective nudge; if it still
        // answers without acting, the run halts honestly ('planError') instead of presenting "Done" over
        // work that never happened. The named "fluent lie" a weak local model tells; the desktop path
        // (Windows/Linux) was missing this backstop the native twins have.
        const goalNeedsAction = looksLikeComputerTask(goal);
        let nudgedForNoAction = false;

        for (let i = 0; i < this.maxSteps; i++) {
            // The kill switch, honored at the top of every turn: stop the WHOLE run instantly,
            // before asking the model to think or act again. Local + cooperative = immediate.
            if (signal?.aborted) return { answer: null, steps, halt: 'cancelled' };
            // CROWN JEWEL (twin of iOS/Android AgentLoop): re-anchor the goal + progress at the
            // transcript TAIL every turn. A small local model attends most to the tail, but the goal
            // is written ONCE at the top and drowns under the growing observation log — the named root
            // cause of multi-step drift. Zero extra decode; the shared cross-platform reliability spine
            // (same text as Swift/Kotlin; recipes stay a macOS UX layer).
            transcript += `\nGOAL (still): ${goal}. Actions taken so far: ${usedTools.length}. Decide the single best next action.`;
            // Opt-in deliberation (twin of the native AgentLoop): reason BEFORE committing to a decision.
            // The think planner runs unconstrained (a thinking budget, no JSON grammar) so the model can
            // actually reason; its output is woven in as a closed <think> block the decision decode sees.
            // Best-effort — a failed/empty think pass never fails the step; it falls through to the decode.
            if (this.think && this.deliberate()) {
                try {
                    const thought = (await this.think(transcript + '\n<think>\n')).trim();
                    if (thought) { transcript += `\n<think>\n${thought}\n</think>`; }
                } catch { /* deliberation is best-effort */ }
                if (signal?.aborted) return { answer: null, steps, halt: 'cancelled' };
            }
            let reply: string;
            try {
                reply = await this.planner(transcript);
            } catch {
                return { answer: null, steps, halt: 'planError' };
            }
            const decision = parseDecision(reply);
            if (!decision) {
                // Give it one corrective nudge with the exact contract; halt only if it slips again.
                if (++parseFailures >= 2) return { answer: null, steps, halt: 'planError' };
                const nudge = 'Your last reply was not valid JSON. Reply with EXACTLY ONE JSON object and nothing else: {"tool":"<name>","input":"<text>"}, {"plan":[{"tool":"<name>","input":"<text>"},…]}, or {"answer":"<text>"}.';
                transcript += `\n${nudge}`;
                emit(nudge);
                continue;
            }
            parseFailures = 0;

            if (decision.kind === 'answer') {
                // Zero attempts on an action goal: "Done" over no work is a lie. One nudge, then halt.
                if (usedTools.length === 0 && goalNeedsAction) {
                    if (!nudgedForNoAction) {
                        nudgedForNoAction = true;
                        const nudge = 'You have not taken any action yet, so an answer now would be false. This goal requires acting through a capability — pick the right one from the list and use it.';
                        transcript += `\n${nudge}`;
                        emit(nudge);
                        continue;
                    }
                    return { answer: null, steps, halt: 'planError' };
                }
                // A completed task teaches the harness — record the proven capability sequence
                // (tool + input) so the next similar goal is primed with concrete plan shape.
                if (usedSteps.length > 0) this.memory?.recordSteps(goal, usedSteps);
                else if (usedTools.length > 0) this.memory?.record(goal, usedTools);
                return { answer: decision.text, steps, halt: 'answered' };
            }

            // Stuck detection: the model proposed the exact action it just ran. Don't re-execute it
            // (that would repeat side effects / re-fail identically) — nudge, and bail if it insists.
            const sig = signatureOf(decision);
            if (sig === prevSig) {
                if (++stall >= 2) return { answer: null, steps, halt: 'stalled' };
                const nudge = `You already ran ${sig} and got: ${lastObs} — do something different, or reply {"answer":"…"} if the task is done.`;
                transcript += `\n${nudge}`;
                emit(nudge);
                continue;
            }
            stall = 0;

            let observation: string;
            if (decision.kind === 'tool') {
                const cap = this.byName.get(decision.name);
                observation = cap
                    ? await this.runner.execute(cap, decision.input, signal)
                    : `No such capability: ${decision.name}.`;
                if (cap) {
                    usedTools.push(decision.name);
                    usedSteps.push({ tool: decision.name, input: decision.input });
                }
                transcript += `\nUsed ${decision.name}(${decision.input}) → ${observation}`;
            } else {
                const resolved = decision.calls.map(c => ({ capability: this.byName.get(c.name), input: c.input }));
                const unknown = resolved.find(r => !r.capability);
                observation = unknown
                    ? `No such capability in the plan: ${decision.calls.find(c => !this.byName.has(c.name))?.name}. Plan not executed.`
                    : await this.runner.executePlan(resolved as Array<{ capability: Capability; input: string }>, signal);
                if (!unknown) {
                    usedTools.push(...decision.calls.map(c => c.name));
                    usedSteps.push(...decision.calls.map(c => ({ tool: c.name, input: c.input })));
                }
                const described = decision.calls.map(c => `${c.name}(${c.input})`).join(', ');
                transcript += `\nProposed plan [${described}] → ${observation}`;
            }
            emit(observation);
            prevSig = sig;
            lastObs = observation;
        }
        return { answer: null, steps, halt: 'maxSteps' };
    }

    private preamble(goal: string): string {
        const list = this.capabilities.map(c => `- ${c.name}: ${c.purpose}`).join('\n');
        const lines = [`Goal: ${goal}`, 'Available capabilities:', list];
        // Retrieval-augmented planning: prime the weak local model with the capability sequences
        // that succeeded on similar past goals. A hint, not a command — it still reasons + gates.
        const recalled = this.memory?.recall(goal) ?? [];
        if (recalled.length > 0) {
            lines.push('You completed similar tasks before — proven sequences (reuse the shape; re-resolve inputs from the live workspace):');
            for (const r of recalled) lines.push(`- ${SkillMemory.formatHint(r)}`);
        }
        lines.push(
            'Respond with ONE JSON object: {"tool":"<name>","input":"<text>"} to use one capability, ' +
            '{"plan":[{"tool":"<name>","input":"<text>"},…]} to propose several steps the user approves ' +
            'together, or {"answer":"<final answer>"} when done.',
            // Twin of the native preamble's anti-narration line: keep a chatty model from ending the
            // mission with a prose {"answer":…} before any real work — narration is not a result.
            'Use {"answer":…} ONLY for the completed final result — never for narration, plans in prose, ' +
            'or intentions. If any calculation or lookup is still needed, use a capability first.',
        );
        return lines.join('\n');
    }
}

/** A stable fingerprint of an action, so the loop can spot the model re-proposing the same thing. */
// Q-552: the stall guard compares action signatures, so whitespace-only differences in the model's
// input (`1 + 1` vs `1  +  1`, trailing spaces, a stray newline) used to read as DIFFERENT actions and
// slip past the "you already ran this" check — the agent re-executed an identical action, repeating side
// effects. Collapse whitespace runs + trim so those unify. Deliberately NOT stripping ALL whitespace:
// that would fuse genuinely-distinct string args (`type("a b")` vs `type("ab")`) and halt too eagerly.
// This normalization is for the SIGNATURE only — execution always uses the raw, unmodified input.
const normSig = (s: string): string => s.trim().replace(/\s+/g, ' ');
function signatureOf(d: Exclude<Decision, { kind: 'answer' }>): string {
    return d.kind === 'tool'
        ? `${d.name}(${normSig(d.input)})`
        : `plan[${d.calls.map(c => `${c.name}(${normSig(c.input)})`).join(', ')}]`;
}

/**
 * Parse the planner's JSON — same shape and precedence (answer > plan > tool) as the native
 * `AgentDecisionParser`, and the same strictness (one tool-less plan item invalidates the plan).
 * Desktop has real JSON.parse, so this stays small; the first-balanced-object extraction guards
 * against prose the model wraps around it (and against a second injected object — H13).
 */
export function parseDecision(raw: string): Decision | null {
    const json = firstJsonObject(raw);
    if (!json) return null;
    let obj: unknown;
    try { obj = JSON.parse(json); } catch { return null; }
    if (typeof obj !== 'object' || obj === null) return null;
    const o = obj as Record<string, unknown>;

    if (typeof o.answer === 'string') return { kind: 'answer', text: o.answer };

    if (Array.isArray(o.plan)) {
        const calls = o.plan.map(item => {
            if (typeof item !== 'object' || item === null) return null;
            const t = (item as Record<string, unknown>).tool;
            const inp = (item as Record<string, unknown>).input;
            if (typeof t !== 'string' || t.length === 0) return null;
            return { name: t, input: typeof inp === 'string' ? inp : '' };
        });
        if (calls.length === 0 || calls.some(c => c === null)) return null;
        return { kind: 'plan', calls: calls as Array<{ name: string; input: string }> };
    }

    if (typeof o.tool === 'string' && o.tool.length > 0) {
        return { kind: 'tool', name: o.tool, input: typeof o.input === 'string' ? o.input : '' };
    }
    return null;
}

