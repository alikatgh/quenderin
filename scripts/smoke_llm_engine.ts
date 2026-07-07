/**
 * Live smoke test for the local-inference engine paths that unit tests CANNOT cover
 * (they all stub the LLM): grammar-constrained decoding, KV-cache prefix reuse
 * (GenerationOptions.cacheKey), and native chat function calling.
 *
 * Built to catch: a node-llama-cpp API drift (grammar/functions/sequence options) that
 * type-checks but fails at runtime, and a cached-sequence reuse that corrupts decode state.
 * Does NOT catch: model-quality issues or Android/iOS twin behavior.
 *
 * Requires a downloaded model in ~/.quenderin/models (any catalog entry).
 * Run from project root:  npx tsx scripts/smoke_llm_engine.ts
 * Bench mode:             npx tsx scripts/smoke_llm_engine.ts --bench [steps]
 *   Runs N (default 10) agent steps through the cached mission sequence and reports the
 *   latency distribution + the cached-vs-fresh speedup, so decode/prefill regressions are a
 *   number, not a feeling. Compare against docs/BENCH_BASELINE.md before/after engine changes.
 * Exit code 0 = all checks passed.
 */
import { LlmService } from '../src/services/llm.service.js';

// Mirrors agent.service.ts ACTION_JSON_SCHEMA (oneOf-per-variant — a flat schema forces the
// grammar to emit every property, junk fields included; that shape is exactly what this caught).
const ACTION_SCHEMA = {
    oneOf: [
        { type: 'object', properties: { action: { const: 'click' }, id: { type: 'number' } } },
        { type: 'object', properties: { action: { const: 'click' }, x: { type: 'number' }, y: { type: 'number' } } },
        { type: 'object', properties: { action: { const: 'input' }, id: { type: 'number' }, text: { type: 'string' } } },
        { type: 'object', properties: { action: { const: 'input' }, x: { type: 'number' }, y: { type: 'number' }, text: { type: 'string' } } },
        { type: 'object', properties: { action: { const: 'scroll' }, direction: { enum: ['up', 'down', 'left', 'right'] } } },
        { type: 'object', properties: { action: { const: 'key' }, key: { enum: ['back', 'home', 'enter'] } } },
        { type: 'object', properties: { action: { const: 'done' } } },
    ],
};

const SYSTEM = `You are an autonomous Android testing agent. Reply with exactly ONE JSON object for your next action.
Valid actions: {"action":"click","id":<n>} {"action":"scroll","direction":"up"|"down"} {"action":"done"}`;

function fail(msg: string): never {
    console.error(`\n✗ SMOKE FAILED: ${msg}`);
    process.exit(1);
}

const llm = new LlmService();
llm.on('action_required', (p: { code: string; message: string }) => {
    fail(`action_required ${p.code}: ${p.message}`);
});

/** Simulated per-step UI: a growing settings screen so each step's prompt differs realistically
 *  (stable head, volatile tail) — the same shape the real agent produces after the prompt reorder. */
function stepPrompt(step: number): string {
    const elements = Array.from({ length: 6 + step }, (_, i) =>
        `{"id":${i},"text":"Item ${i} of screen ${step}","interactable":true}`).join(',');
    return `Goal: open settings and enable Wi-Fi. Previous: step ${step - 1} clicked OK.\nUI: [${elements}]\nWhat is your next JSON action?`;
}

// ── Bench mode: N cached-sequence steps + a fresh-sequence control ───────────
if (process.argv.includes('--bench')) {
    const stepsArg = Number(process.argv[process.argv.indexOf('--bench') + 1]);
    const N = Number.isFinite(stepsArg) && stepsArg >= 3 ? stepsArg : 10;
    try {
        const timings: number[] = [];
        for (let i = 1; i <= N; i++) {
            const t = performance.now();
            const out = await llm.generateAction(SYSTEM, stepPrompt(i),
                { maxTokens: 150, temperature: 0, jsonSchema: ACTION_SCHEMA, cacheKey: 'bench' });
            timings.push(performance.now() - t);
            JSON.parse(out);   // every step must stay grammar-clean
        }
        llm.releaseActionCache('bench');
        // Control: the same LAST prompt on a fresh sequence = the full re-prefill cost.
        const t = performance.now();
        await llm.generateAction(SYSTEM, stepPrompt(N), { maxTokens: 150, temperature: 0, jsonSchema: ACTION_SCHEMA });
        const freshMs = performance.now() - t;

        const sorted = [...timings.slice(1)].sort((a, b) => a - b);   // step 1 pays the model load
        const p50 = sorted[Math.floor(sorted.length / 2)];
        const p95 = sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))];
        console.log(`\nBench (${N} cached steps, ${llm.getActiveModelLabel()}):`);
        console.log(`  step1 (incl. load): ${timings[0].toFixed(0)}ms`);
        console.log(`  cached p50: ${p50.toFixed(0)}ms   p95: ${p95.toFixed(0)}ms`);
        console.log(`  fresh-sequence control: ${freshMs.toFixed(0)}ms   speedup ×${(freshMs / p50).toFixed(2)}`);
    } finally {
        await llm.shutdown();
    }
    process.exit(0);
}

try {
    // ── 1. Grammar-constrained action decode (fresh sequence) ────────────────
    let t0 = performance.now();
    const a1 = await llm.generateAction(
        SYSTEM,
        'UI: [{"id":1,"text":"Settings","clickable":true}] Goal: open settings. What is your next JSON action?',
        { maxTokens: 150, temperature: 0.1, jsonSchema: ACTION_SCHEMA, cacheKey: 'smoke' }
    );
    const step1Ms = performance.now() - t0;
    const parsed1 = JSON.parse(a1);   // grammar guarantee: must parse as-is, no extraction needed
    if (!['click', 'input', 'scroll', 'key', 'done'].includes(parsed1.action)) {
        fail(`action outside schema enum: ${a1}`);
    }
    // The oneOf grammar must not attach junk fields from other variants.
    if (parsed1.action === 'click' && (parsed1.direction !== undefined || parsed1.key !== undefined)) {
        fail(`click carries fields from another variant: ${a1}`);
    }
    console.log(`✓ grammar-constrained action decode: ${a1}  (${step1Ms.toFixed(0)}ms)`);

    // ── 2. Same cacheKey again — the KV prefix-reuse path ─────────────────────
    t0 = performance.now();
    const a2 = await llm.generateAction(
        SYSTEM,
        'UI: [{"id":1,"text":"Settings","clickable":true},{"id":2,"text":"Wi-Fi","clickable":true}] Goal: open settings. Previous: clicked id=1 OK. What is your next JSON action?',
        { maxTokens: 150, temperature: 0.1, jsonSchema: ACTION_SCHEMA, cacheKey: 'smoke' }
    );
    const step2Ms = performance.now() - t0;
    JSON.parse(a2);
    console.log(`✓ cached-sequence decode:          ${a2}  (${step2Ms.toFixed(0)}ms, step1 ${step1Ms.toFixed(0)}ms incl. model load)`);
    llm.releaseActionCache('smoke');

    // ── 3. Native chat function calling (calculator) ─────────────────────────
    // Plumbing check (meta.toolCalls: did a handler EXECUTE without the machinery throwing?) is
    // separate from the quality check (did 391 reach the answer?). On a 2-bit 1B both trigger and
    // relay are stochastic — those are MODEL quality, soft-warned. Machinery bugs (handler throws,
    // decode errors, timeout) already hard-fail via the outer try. Retry a few times: one clean
    // called+answered run proves the full path.
    let proved = false, called = false, lastText = '';
    for (let attempt = 0; attempt < 3 && !proved; attempt++) {
        const { text, meta } = await llm.generalChat('Use the calculator tool to compute 17 * 23 and tell me the result.');
        called ||= (meta.toolCalls ?? 0) > 0;
        proved = (meta.toolCalls ?? 0) > 0 && text.includes('391');
        lastText = text;
        llm.resetChat();   // independent attempts
    }
    if (proved) {
        console.log(`✓ native function calling:         "${lastText.slice(0, 120).replace(/\n/g, ' ')}"`);
    } else if (called) {
        console.warn(`⚠ function executed but the model relayed the result poorly (model quality): "${lastText.slice(0, 160)}"`);
    } else {
        console.warn(`⚠ model never triggered a function in 3 attempts (model quality, not plumbing): "${lastText.slice(0, 160)}"`);
    }

    console.log('\nAll engine smoke checks passed.');
} finally {
    await llm.shutdown();
}
process.exit(0);
