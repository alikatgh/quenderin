import os from 'os';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { checkMemoryForModel, getBestInstallableModel, MODEL_CATALOG } from '../src/constants.js';
import * as memory from '../src/utils/memory.js';
import {
    getModelRuntimeCompatibility, PRISM_LLAMA_CPP_REPO, PRISM_LLAMA_CPP_REVISION,
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

    it('keeps standard models compatible without a Prism addon', () => {
        for (const entry of MODEL_CATALOG.filter(m => m.id !== 'bonsai2-27b')) {
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
});
