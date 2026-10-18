import os from 'os';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
    checkMemoryForModel, getBestInstallableModel, getRecommendedModelIdForTotalRam,
    MODEL_CATALOG, type ModelEntry,
} from '../src/constants.js';
import * as runtime from '../src/services/modelRuntime.js';
import * as memory from '../src/utils/memory.js';

const experimental = [
    ['minicpm-v47-1b', 2.0, 1.15],
    ['minicpm-v47-35b-a3b', 25.0, 1.3],
    ['lfm25-24b-a2b', 18.0, 1.3],
    ['jais3-0.9b', 2.0, 1.15],
    ['jais3-3.7b', 6.0, 1.3],
    ['jais3-7b', 9.0, 1.3],
    ['jais3-32b', 28.0, 1.3],
    ['jais3-mova-36b-a4b', 30.0, 1.3],
    ['nemotron35-bolt-74b-a9b', 28.0, 1.3],
] as const;

beforeEach(() => {
    vi.spyOn(os, 'totalmem').mockReturnValue(512 * 1024 ** 3);
    vi.spyOn(memory, 'availableMemBytes').mockReturnValue(512 * 1024 ** 3);
});

afterEach(() => vi.restoreAllMocks());

describe('experimental weekly text catalog choices', () => {
    it.each(experimental)('keeps full-weight memory plus overhead for %s', (id, floor, overhead) => {
        const entry = MODEL_CATALOG.find(model => model.id === id)!;
        expect(entry.label).toContain('(Experimental, text only)');
        expect(checkMemoryForModel(entry).requiredMemoryGB).toBeCloseTo(floor * overhead);
        expect(checkMemoryForModel({ ...entry, ramGb: 0.1 } as unknown as ModelEntry).requiredMemoryGB)
            .toBeCloseTo(floor * overhead);
    });

    it.each([
        ['minicpm-v47-1b', 25],
        ['jais3-0.9b', 30],
    ] as const)('refuses the smaller %s memory floor when artifact identity changes', (id, importedFloor) => {
        const entry = MODEL_CATALOG.find(model => model.id === id)!;
        for (const change of [{ sha256: undefined }, { downloadBytes: 1 }, { url: 'https://example.com/model.gguf' }]) {
            const imported = { ...entry, ...change, ramGb: 0.1 } as unknown as ModelEntry;
            expect(checkMemoryForModel(imported).requiredMemoryGB).toBeCloseTo(importedFloor * 1.15);
        }
    });

    it('keeps manual choices out of defaults and fallback selection even when their runtime is available', () => {
        // Force fallback selection while allowing every experimental model to pass the
        // separate runtime/memory checks. Recency must not silently change the default.
        vi.spyOn(runtime, 'getModelRuntimeCompatibility').mockImplementation(entry => ({
            canLoad: entry.id !== 'qwen3-14b' && entry.id !== 'muse-spark-open-q2-k',
            message: 'Controlled runtime availability for fallback selection.',
        }));
        const experimentalIDs = experimental.map(([id]) => id);
        for (const ram of [1, 2, 4, 8, 16, 64, 512]) {
            expect(experimentalIDs).not.toContain(getRecommendedModelIdForTotalRam(ram));
        }
        expect(getBestInstallableModel(64)).toBe('gemma4-12b');
    });
});
