import { describe, it, expect } from 'vitest';
import { maxToolCallsPerResponse, buildToolPrompt } from '../src/services/tools/registry.js';
import { executeToolCalls } from '../src/services/tools/handlers.js';

/**
 * Q-639: the tool prompt TELLS the model how many tool calls it may make (1/2/3 by hardware tier), and
 * the executor ENFORCES a cap — but they were out of sync (the executor hardcoded 5). Both now derive
 * from maxToolCallsPerResponse(), so what the model is promised is exactly what runs.
 */
describe('tool-call cap parity (Q-639)', () => {
    it('the prompt advertises exactly the cap the executor enforces', async () => {
        const cap = maxToolCallsPerResponse();
        expect(cap).toBeGreaterThanOrEqual(1);

        // The prompt tells the model this number verbatim...
        expect(buildToolPrompt()).toContain(`up to ${cap} tool calls`);

        // ...and the executor enforces it: more calls than the cap → only `cap` run.
        const calls = Array.from({ length: cap + 3 }, () => ({ tool: 'calculator', args: { expression: '1+1' } }));
        const results = await executeToolCalls(calls);
        expect(results.length).toBe(cap);
    });
});
