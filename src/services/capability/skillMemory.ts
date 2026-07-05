/**
 * Skill memory — the harness's answer to grounding, our honest weak spot. A small local model
 * struggles to CHOOSE the right capability; a cloud agent re-derives every task from scratch.
 * Ours remembers what worked: after a task succeeds, it records goal → the capabilities that got
 * there, and primes the next similar goal with those proven sequences. The agent gets reliably
 * better at chores you repeat, locally, with no bigger model. Retrieval-augmented planning — the
 * recalled sequence is a HINT the model still reasons over, and everything still goes through the
 * full gate, so it's safe by construction.
 */
export interface SkillRecord {
    goal: string;
    tools: string[];   // capability names used, in order, on a run that reached an answer
}

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
        const g = goal.trim();
        if (!g || tools.length === 0) return;
        const existing = this.records.findIndex(r => r.goal.toLowerCase() === g.toLowerCase());
        if (existing >= 0) this.records.splice(existing, 1);
        this.records.push({ goal: g, tools: [...tools] });
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

    get size(): number { return this.records.length; }
}
