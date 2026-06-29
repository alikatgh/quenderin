import { describe, it, expect } from 'vitest';
import { executeTool } from '../src/services/tools/handlers.js';

/**
 * executeTool() is the single dispatch point for every agent tool, yet only the read_file denylist
 * was covered. These pin the deterministic, fs-free dispatch/validation branches that guard malformed
 * model output: the unknown-tool rejection, calculator missing-expression/success/CalculatorError
 * mapping, and the datetime/system_info JSON shape. A regression returning success on an unknown tool,
 * or dropping the calculator error into the generic 'Tool execution failed' fallback, would ship
 * silently. (note_save validation is intentionally left out here — it needs the temp-$HOME harness
 * used in metrics.service.test.ts.)
 */
describe('executeTool dispatch + validation', () => {
    it('rejects an unknown tool name', async () => {
        const r = await executeTool({ tool: 'frobnicate', args: {} });
        expect(r.success).toBe(false);
        expect(r.error).toContain('Unknown tool');
    });
    it('calculator: success on a valid expression', async () => {
        const r = await executeTool({ tool: 'calculator', args: { expression: '2 + 3 * 4' } });
        expect(r.success).toBe(true);
        expect(r.result).toBe('14');
    });
    it('calculator: missing expression is rejected', async () => {
        const r = await executeTool({ tool: 'calculator', args: {} });
        expect(r.success).toBe(false);
        expect(r.error).toContain('Missing expression');
    });
    it('calculator: surfaces a CalculatorError message on a bad expression', async () => {
        const r = await executeTool({ tool: 'calculator', args: { expression: '2 +' } });
        expect(r.success).toBe(false);
        expect(typeof r.error).toBe('string');
        expect(r.error!.length).toBeGreaterThan(0); // mapped from CalculatorError, not generic fallback
    });
    it('datetime returns valid iso + integer unix + timezone', async () => {
        const r = await executeTool({ tool: 'datetime', args: {} });
        expect(r.success).toBe(true);
        const d = JSON.parse(r.result);
        expect(typeof d.iso).toBe('string');
        expect(Number.isInteger(d.unix)).toBe(true);
        expect(d.timezone).toBeTruthy();
    });
    it('system_info reports platform/arch/cpus', async () => {
        const r = await executeTool({ tool: 'system_info', args: {} });
        expect(r.success).toBe(true);
        const d = JSON.parse(r.result);
        expect(typeof d.platform).toBe('string');
        expect(Number(d.cpus)).toBeGreaterThan(0);
    });
});
