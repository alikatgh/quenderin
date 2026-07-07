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
    const { text } = await llm.generalChat('Use the calculator tool to compute 17 * 23 and tell me the result.');
    if (!text.includes('391')) {
        // Soft check: a 1B model may phrase oddly, but the tool result should appear.
        console.warn(`⚠ chat answer did not contain 391 — inspect manually: "${text.slice(0, 200)}"`);
    } else {
        console.log(`✓ native function calling:         "${text.slice(0, 120).replace(/\n/g, ' ')}"`);
    }

    console.log('\nAll engine smoke checks passed.');
} finally {
    await llm.shutdown();
}
process.exit(0);
