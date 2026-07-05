import { Capability } from './capability.js';
import { CapabilityRunner } from './runner.js';

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
    halt: 'answered' | 'maxSteps' | 'planError';
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
    ) {
        this.byName = new Map(capabilities.map(c => [c.name, c]));
    }

    async run(goal: string): Promise<AgentResult> {
        const steps: string[] = [];
        let transcript = this.preamble(goal);

        for (let i = 0; i < this.maxSteps; i++) {
            let reply: string;
            try {
                reply = await this.planner(transcript);
            } catch {
                return { answer: null, steps, halt: 'planError' };
            }
            const decision = parseDecision(reply);
            if (!decision) return { answer: null, steps, halt: 'planError' };

            if (decision.kind === 'answer') {
                return { answer: decision.text, steps, halt: 'answered' };
            }

            let observation: string;
            if (decision.kind === 'tool') {
                const cap = this.byName.get(decision.name);
                observation = cap
                    ? await this.runner.execute(cap, decision.input)
                    : `No such capability: ${decision.name}.`;
                transcript += `\nUsed ${decision.name}(${decision.input}) → ${observation}`;
            } else {
                const resolved = decision.calls.map(c => ({ capability: this.byName.get(c.name), input: c.input }));
                const unknown = resolved.find(r => !r.capability);
                observation = unknown
                    ? `No such capability in the plan: ${decision.calls.find(c => !this.byName.has(c.name))?.name}. Plan not executed.`
                    : await this.runner.executePlan(resolved as Array<{ capability: Capability; input: string }>);
                const described = decision.calls.map(c => `${c.name}(${c.input})`).join(', ');
                transcript += `\nProposed plan [${described}] → ${observation}`;
            }
            steps.push(observation);
        }
        return { answer: null, steps, halt: 'maxSteps' };
    }

    private preamble(goal: string): string {
        const list = this.capabilities.map(c => `- ${c.name}: ${c.purpose}`).join('\n');
        return [
            `Goal: ${goal}`,
            'Available capabilities:',
            list,
            'Respond with ONE JSON object: {"tool":"<name>","input":"<text>"} to use one capability, ' +
            '{"plan":[{"tool":"<name>","input":"<text>"},…]} to propose several steps the user approves ' +
            'together, or {"answer":"<final answer>"} when done.',
        ].join('\n');
    }
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

/** The first complete, balanced `{ … }` object (strings skipped) — twin of the native parser. */
function firstJsonObject(text: string): string | null {
    const start = text.indexOf('{');
    if (start < 0) return null;
    let depth = 0, inString = false, escaped = false;
    for (let i = start; i < text.length; i++) {
        const c = text[i];
        if (inString) {
            if (escaped) escaped = false;
            else if (c === '\\') escaped = true;
            else if (c === '"') inString = false;
        } else if (c === '"') inString = true;
        else if (c === '{') depth++;
        else if (c === '}') { depth--; if (depth === 0) return text.slice(start, i + 1); }
    }
    return null;
}
