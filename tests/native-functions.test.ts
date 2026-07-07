import { describe, expect, it } from 'vitest';
import { buildNativeChatFunctions } from '../src/services/tools/nativeFunctions.js';
import { AVAILABLE_TOOLS, maxToolCallsPerResponse } from '../src/services/tools/registry.js';

// A stand-in for node-llama-cpp's defineChatSessionFunction: it just returns the definition,
// which lets the tests reach the description/params/handler the bridge produced.
type FnDef = { description: string; params?: Record<string, unknown>; handler: (p?: Record<string, unknown>) => Promise<unknown> };
const fakeDefine = (def: unknown) => def;

function build(onToolCall?: (t: string) => void): Record<string, FnDef> {
    return buildNativeChatFunctions(fakeDefine, onToolCall) as Record<string, FnDef>;
}

describe('buildNativeChatFunctions — the native tool bridge', () => {
    it('exposes every registry tool with its description, and schemas only for parameterized tools', () => {
        const fns = build();
        expect(Object.keys(fns).sort()).toEqual(AVAILABLE_TOOLS.map(t => t.name).sort());
        for (const tool of AVAILABLE_TOOLS) {
            expect(fns[tool.name].description).toBe(tool.description);
            if (tool.parameters.length === 0) {
                expect(fns[tool.name].params).toBeUndefined();
            } else {
                const props = (fns[tool.name].params as { properties: Record<string, unknown> }).properties;
                expect(Object.keys(props).sort()).toEqual(tool.parameters.map(p => p.name).sort());
            }
        }
    });

    it('routes execution through the real handlers (calculator actually calculates)', async () => {
        const calls: string[] = [];
        const fns = build(t => calls.push(t));
        const out = await fns.calculator.handler({ expression: '6*7' });
        expect(out).toBe('42');
        expect(calls).toEqual(['calculator']);
    });

    it('returns a structured error (not a throw) for a failing call, so the model can recover', async () => {
        const fns = build();
        const out = await fns.calculator.handler({});   // missing expression
        expect(out).toMatchObject({ error: expect.stringContaining('expression') });
    });

    it('keeps the read_file secret-store denial intact through the native path (safety funnel)', async () => {
        const fns = build();
        const out = await fns.read_file.handler({ path: '~/.ssh/id_rsa' });
        expect(out).toMatchObject({ error: expect.stringContaining('sensitive') });
    });

    it('enforces the Q-639 per-response cap: past the limit the model gets a visible refusal', async () => {
        const cap = maxToolCallsPerResponse();
        const executed: string[] = [];
        const fns = build(t => executed.push(t));
        for (let i = 0; i < cap; i++) {
            expect(await fns.calculator.handler({ expression: '1+1' })).toBe('2');
        }
        const over = await fns.calculator.handler({ expression: '1+1' });
        expect(over).toMatchObject({ error: expect.stringContaining('limit') });
        expect(executed.length).toBe(cap);   // the over-cap call never reached the handler
    });

    it('the cap counter is per-map (per response), not global', async () => {
        const cap = maxToolCallsPerResponse();
        const first = build();
        for (let i = 0; i < cap; i++) await first.calculator.handler({ expression: '1' });
        // A FRESH map (new response) starts from zero.
        const second = build();
        expect(await second.calculator.handler({ expression: '2+2' })).toBe('4');
    });
});
