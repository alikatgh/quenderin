import { describe, expect, it, vi } from 'vitest';

// getBestInstallableModel reads live memory via these three inputs; pin them so the
// step-down logic is deterministic regardless of the machine running the suite.
const mem = { totalGb: 32, freeGb: 32 };

vi.mock('../src/utils/memory.js', () => ({
    availableMemBytes: () => mem.freeGb * 1024 ** 3,
}));

vi.mock('../src/utils/hardware.js', () => ({
    getHardwareProfile: () => ({ memoryBudgetHard: 0.85 }),
}));

vi.mock('os', async (importOriginal) => {
    const actual = await importOriginal<typeof import('os')>();
    const totalmem = () => mem.totalGb * 1024 ** 3;
    return { ...actual, totalmem, default: { ...actual, totalmem } };
});

import { getBestInstallableModel, getRecommendedModelIdForTotalRam } from '../src/constants.js';

describe('getBestInstallableModel', () => {
    it('returns the band pick when it passes the memory gate', () => {
        mem.totalGb = 32;
        mem.freeGb = 32;
        // qwen3-14b needs 11.0 × 1.3 = 14.3GB → 44.7% of 32GB, well under the 85% budget
        expect(getBestInstallableModel(32)).toBe('qwen3-14b');
        expect(getBestInstallableModel(32)).toBe(getRecommendedModelIdForTotalRam(32));
    });

    it('steps down to the largest fitting model when the band pick is blocked', () => {
        mem.totalGb = 16;
        mem.freeGb = 16;
        // Band picks qwen3-14b (14.3GB → 89.4% of 16GB, blocked by the 85% budget);
        // largest fitting entry is gemma4-12b (9.0 × 1.3 = 11.7GB → 73.1%).
        expect(getRecommendedModelIdForTotalRam(16)).toBe('qwen3-14b');
        expect(getBestInstallableModel(16)).toBe('gemma4-12b');
    });

    it('falls back to the smallest model when nothing passes the gate', () => {
        mem.totalGb = 16;
        mem.freeGb = 1;
        // 15GB already in use — even llama32-1b-q2 (0.805GB) lands at 98.8% usage.
        expect(getBestInstallableModel(16)).toBe('llama32-1b-q2');
    });
});
