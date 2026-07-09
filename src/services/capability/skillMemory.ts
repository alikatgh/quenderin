/**
 * Skill memory — the harness's answer to grounding, our honest weak spot. A small local model
 * struggles to CHOOSE the right capability; a cloud agent re-derives every task from scratch.
 * Ours remembers what worked: after a task succeeds, it records goal → the capabilities (and
 * optionally their inputs) that got there, and primes the next similar goal with those proven
 * sequences. The agent gets reliably better at chores you repeat, locally, with no bigger model.
 * Retrieval-augmented planning — the recalled sequence is a HINT the model still reasons over,
 * and everything still goes through the full gate, so it's safe by construction.
 */
export interface SkillStep {
    tool: string;
    /** Raw input that succeeded with the tool (may be empty). Capped on record. */
    input: string;
}

export interface SkillRecord {
    goal: string;
    /** Capability names in order — always present for twin/parity and simple recall. */
    tools: string[];
    /** Richer sequence when available (tool + input). Optional for older snapshots. */
    steps?: SkillStep[];
}

/** Hard caps so a hand-edited/poisoned ~/.quenderin/agent-skills.json can't bloat the planner
 *  preamble (Q-280). Real goals are a sentence; real tool sequences are a handful of steps. */
const MAX_GOAL_LEN = 300;
const MAX_TOOLS = 40;
const MAX_INPUT_LEN = 120;

/** Lowercase word tokens, deduped — the unit of goal similarity. */
function tokens(text: string): Set<string> {
    return new Set(text.toLowerCase().split(/[^a-z0-9]+/).filter(t => t.length > 2));
}

/** Overlap coefficient: |A∩B| / min(|A|,|B|) — robust when goals differ in length. */
function similarity(a: Set<string>, b: Set<string>): number {
    if (a.size === 0 || b.size === 0) return 0;
    let shared = 0;
    for (const t of a) if (b.has(t)) shared++;
    return shared / Math.min(a.size, b.size);
}

function sanitizeSteps(steps: SkillStep[]): SkillStep[] {
    const out: SkillStep[] = [];
    for (const s of steps.slice(0, MAX_TOOLS)) {
        if (typeof s?.tool !== 'string' || !s.tool.trim()) continue;
        out.push({
            tool: s.tool.trim().slice(0, 64),
            input: typeof s.input === 'string' ? s.input.trim().slice(0, MAX_INPUT_LEN) : '',
        });
    }
    return out;
}

export class SkillMemory {
    private readonly records: SkillRecord[] = [];

    constructor(
        /** Below this goal-similarity, a past skill isn't offered (avoid irrelevant priming). */
        private readonly threshold = 0.5,
        /** Cap memory so it can't grow unbounded; oldest drop first. */
        private readonly capacity = 200,
    ) { }

    /** Remember that `tools` accomplished `goal`. Ignores empty runs; de-dupes an identical goal
     *  (keeps the most recent tool sequence for it). */
    record(goal: string, tools: string[]): void {
        const g = goal.trim().slice(0, MAX_GOAL_LEN);
        if (!g || tools.length === 0) return;
        this.upsert({ goal: g, tools: tools.slice(0, MAX_TOOLS).map(t => String(t).slice(0, 64)) });
    }

    /**
     * Remember a full proven sequence (tool + input). Derives `tools` for twin-compatible recall.
     * Prefer this from CapabilityAgent so the next similar goal gets concrete plan shape, not just
     * bare tool names ("fs.move" vs `fs.move("report.pdf to Documents")`).
     */
    recordSteps(goal: string, steps: SkillStep[]): void {
        const g = goal.trim().slice(0, MAX_GOAL_LEN);
        const clean = sanitizeSteps(steps);
        if (!g || clean.length === 0) return;
        this.upsert({
            goal: g,
            tools: clean.map(s => s.tool),
            steps: clean,
        });
    }

    private upsert(rec: SkillRecord): void {
        const existing = this.records.findIndex(r => r.goal.toLowerCase() === rec.goal.toLowerCase());
        if (existing >= 0) this.records.splice(existing, 1);
        this.records.push(rec);
        while (this.records.length > this.capacity) this.records.shift();
    }

    /** The most similar past skills to `goal`, best first (up to `k`), above the threshold. */
    recall(goal: string, k = 2): SkillRecord[] {
        const target = tokens(goal);
        return this.records
            .map(r => ({ r, score: similarity(target, tokens(r.goal)) }))
            .filter(x => x.score >= this.threshold)
            .sort((a, b) => b.score - a.score)
            .slice(0, k)
            .map(x => x.r);
    }

    /**
     * Format a recalled skill as a one-line planner hint.
     * With steps: `fs.list → fs.move("a.pdf to Docs")`; without: bare tool chain.
     */
    static formatHint(rec: SkillRecord): string {
        if (rec.steps && rec.steps.length > 0) {
            const chain = rec.steps.map(s => {
                if (!s.input) return s.tool;
                const shown = s.input.length > 60 ? s.input.slice(0, 60) + '…' : s.input;
                return `${s.tool}(${JSON.stringify(shown)})`;
            }).join(' → ');
            return `"${rec.goal}" → ${chain}`;
        }
        return `"${rec.goal}" → ${rec.tools.join(' → ')}`;
    }

    get size(): number { return this.records.length; }

    /** A copy of the records — for persisting across sessions (the reliability loop is only real
     *  if memory survives a restart; in the CLI, each `quenderin do` is a fresh process). */
    snapshot(): SkillRecord[] {
        return this.records.map(r => ({
            goal: r.goal,
            tools: [...r.tools],
            ...(r.steps ? { steps: r.steps.map(s => ({ tool: s.tool, input: s.input })) } : {}),
        }));
    }

    /** Replace the records from a persisted snapshot (validated — junk rows are dropped). */
    restore(records: unknown): void {
        this.records.length = 0;
        if (!Array.isArray(records)) return;
        for (const r of records) {
            const rec = r as Partial<SkillRecord>;
            if (typeof rec?.goal !== 'string' || !Array.isArray(rec.tools) || !rec.tools.every(t => typeof t === 'string')) {
                continue;
            }
            const tools = rec.tools.slice(0, MAX_TOOLS).map(t => String(t).slice(0, 64));
            if (tools.length === 0) continue;
            let steps: SkillStep[] | undefined;
            if (Array.isArray(rec.steps)) {
                steps = sanitizeSteps(rec.steps as SkillStep[]);
                if (steps.length === 0) steps = undefined;
            }
            this.records.push({
                goal: rec.goal.slice(0, MAX_GOAL_LEN),
                tools,
                ...(steps ? { steps } : {}),
            });
            if (this.records.length >= this.capacity) break;
        }
    }
}
