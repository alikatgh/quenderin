import os from 'os';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { checkMemoryForModel, getBestInstallableModel, getRecommendedModelIdForTotalRam, MODEL_CATALOG, type ModelEntry } from '../src/constants.js';
import * as memory from '../src/utils/memory.js';
import {
    getModelRuntimeCompatibility, requiresPrismRuntime, PRISM_LLAMA_CPP_REPO, PRISM_LLAMA_CPP_REVISION,
} from '../src/services/modelRuntime.js';

const prism = {
    buildType: 'localBuild',
    llamaCppRelease: { repo: PRISM_LLAMA_CPP_REPO, release: PRISM_LLAMA_CPP_REVISION },
};

afterEach(() => vi.restoreAllMocks());

describe('desktop model runtime compatibility', () => {
    it.each([
        { quantization: 'PTQ1_0' },
        { quantization: 'pq2_0' },
        { id: 'bonsai2-27b' },
        { filename: 'renamed.PTQ1_0.gguf' },
        { filename: 'Ternary-Bonsai-2-27B.gguf' },
    ])('gates arbitrary imported descriptors as well as catalog entries: %j', entry => {
        expect(getModelRuntimeCompatibility(entry).canLoad).toBe(false);
        expect(getModelRuntimeCompatibility(entry, prism).canLoad).toBe(true);
    });

    it.each([
        undefined,
        { buildType: 'prebuilt', llamaCppRelease: prism.llamaCppRelease },
        { buildType: 'localBuild', llamaCppRelease: { repo: 'ggml-org/llama.cpp', release: PRISM_LLAMA_CPP_REVISION } },
        { buildType: 'localBuild', llamaCppRelease: { repo: PRISM_LLAMA_CPP_REPO, release: 'main' } },
    ])('rejects missing, stock, and unpinned addon metadata: %j', runtime => {
        const result = getModelRuntimeCompatibility({ quantization: 'PTQ1_0' }, runtime);
        expect(result.canLoad).toBe(false);
        expect(result.message).toContain('Prism llama.cpp');
    });

    it('keeps Muse disabled without a desktop multipart/chat adapter even with the Prism addon', () => {
        const muse = MODEL_CATALOG.find(m => m.id === 'muse-spark-open-q2-k')!;
        expect(getModelRuntimeCompatibility(muse, prism).canLoad).toBe(false);
        expect(getModelRuntimeCompatibility(muse, prism).message).toContain('Electron/CLI');
    });

    it('keeps standard models compatible without a Prism addon', () => {
        for (const entry of MODEL_CATALOG.filter(m => !requiresPrismRuntime(m) && !m.id.startsWith('muse-'))) {
            expect(getModelRuntimeCompatibility(entry).canLoad).toBe(true);
        }
    });

    it('blocks unsupported formats even with abundant RAM, without mistaking the download size for RAM', () => {
        vi.spyOn(os, 'totalmem').mockReturnValue(64 * 1024 ** 3);
        vi.spyOn(memory, 'availableMemBytes').mockReturnValue(64 * 1024 ** 3);
        const bonsai = MODEL_CATALOG.find(m => m.id === 'bonsai2-27b')!;
        const blocked = checkMemoryForModel(bonsai);
        expect(blocked.canLoad).toBe(false);
        expect(blocked.severity).toBe('blocked');
        expect(blocked.message).toContain('Prism llama.cpp');
        expect(blocked.requiredMemoryGB).toBeCloseTo(7 * 1.3);
        expect(checkMemoryForModel(bonsai, prism).canLoad).toBe(true);
        expect(getBestInstallableModel(64)).toBe('qwen3-14b');
    });

    it.each([
        ['bonsai2-2b', 1.95], ['bonsai2-4b', 3.25], ['bonsai2-9b', 5.2], ['bonsai2-27b', 9.1],
    ] as const)('keeps runtime capability and conservative memory independent for %s', (id, required) => {
        vi.spyOn(os, 'totalmem').mockReturnValue(64 * 1024 ** 3);
        const free = vi.spyOn(memory, 'availableMemBytes').mockReturnValue(64 * 1024 ** 3);
        const entry = MODEL_CATALOG.find(model => model.id === id)!;
        expect(checkMemoryForModel(entry).canLoad).toBe(false);
        expect(checkMemoryForModel(entry, prism).requiredMemoryGB).toBeCloseTo(required);
        expect(checkMemoryForModel(entry, prism).canLoad).toBe(true);
        free.mockReturnValue(required / 2 * 1024 ** 3);
        expect(checkMemoryForModel(entry, prism).canLoad).toBe(false);
    });

    it('retains the conservative imported-Bonsai floor when small-model metadata is missing or changed', () => {
        vi.spyOn(os, 'totalmem').mockReturnValue(64 * 1024 ** 3);
        vi.spyOn(memory, 'availableMemBytes').mockReturnValue(64 * 1024 ** 3);
        const known = MODEL_CATALOG.find(model => model.id === 'bonsai2-2b')!;
        expect(checkMemoryForModel({ ...known, ramGb: 0.1 } as ModelEntry, prism).requiredMemoryGB).toBeCloseTo(1.95);
        for (const change of [{ sha256: undefined }, { url: 'https://example.com/custom.gguf' }, { downloadBytes: 1 }, { paramsBillions: 27 }]) {
            const imported = { ...known, ...change, ramGb: 0.1 } as unknown as ModelEntry;
            expect(checkMemoryForModel(imported, prism).requiredMemoryGB).toBeCloseTo(9.1);
        }
    });

    it('keeps Bonsai out of automatic recommendations across RAM bands', () => {
        vi.spyOn(os, 'totalmem').mockReturnValue(64 * 1024 ** 3);
        vi.spyOn(memory, 'availableMemBytes').mockReturnValue(64 * 1024 ** 3);
        for (const ram of [0.5, 1.5, 3, 4, 8, 12, 16, 64]) {
            expect(getRecommendedModelIdForTotalRam(ram)).not.toContain('bonsai');
            expect(getBestInstallableModel(ram)).not.toContain('bonsai');
        }
    });
});
