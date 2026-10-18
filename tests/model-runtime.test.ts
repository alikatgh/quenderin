import os from 'os';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { checkMemoryForModel, getBestInstallableModel, getRecommendedModelIdForTotalRam, MODEL_CATALOG, type ModelEntry } from '../src/constants.js';
import * as memory from '../src/utils/memory.js';
import {
    getModelRuntimeCompatibility, requiresPrismRuntime, PRISM_LLAMA_CPP_REPO, PRISM_LLAMA_CPP_REVISION,
    requiresWeeklyTextRuntime,
} from '../src/services/modelRuntime.js';

const prism = {
    buildType: 'localBuild',
    llamaCppRelease: { repo: PRISM_LLAMA_CPP_REPO, release: PRISM_LLAMA_CPP_REVISION },
};

afterEach(() => vi.restoreAllMocks());

describe('desktop model runtime compatibility', () => {
    it.each([
        'Beam-1.0-501B-A23B', 'Hy-Memory-30B-A3B', 'NVIDIA-Nemotron-3.5-Super-VL-120B-A12B',
        'Step-5-Preview', 'Granite-Switch-4.1', 'NVIDIA-Nemotron-3.5-Bolt-E4B', 'Nemotron-3.5-Unknown',
        'Bolt-E4B', 'Super-VL-120B', 'Beam1.0-501B',
    ])('blocks unavailable workflows across all descriptor aliases: %s', name => {
        for (const field of ['id', 'label', 'filename', 'url'] as const) {
            const entry = { [field]: name };
            expect(getModelRuntimeCompatibility(entry, { ...prism, weeklyTextABI: 1 }).canLoad).toBe(false);
        }
    });

    it('lets actual architecture/name override a harmless or validated alias', () => {
        const runtime = { ...prism, weeklyTextABI: 1 };
        for (const architecture of ['beam', 'step5', 'step5_vl']) {
            expect(getModelRuntimeCompatibility({ id: 'ordinary', architecture }, runtime).canLoad).toBe(false);
        }
        expect(getModelRuntimeCompatibility({ id: 'nemotron35-bolt-74b-a9b', modelName: 'Nemotron-3.5-Super-120B' }, runtime).canLoad).toBe(false);
        expect(getModelRuntimeCompatibility({ id: 'ordinary', architecture: 'hy_v3', modelName: 'Hy-Memory-30B-A3B' }, runtime).canLoad).toBe(false);
        expect(getModelRuntimeCompatibility({ url: 'https://example.invalid/Hy%2DMemory%2D30B.gguf' }, runtime).canLoad).toBe(false);
        expect(getModelRuntimeCompatibility({ architecture: 'a'.repeat(257) }, runtime).canLoad).toBe(false);
        expect(getModelRuntimeCompatibility({ modelName: 'a'.repeat(16_385) }, runtime).canLoad).toBe(false);
    });

    it('preserves older families and all nine pinned weekly text entries', () => {
        for (const name of ['Granite-4.0', 'Hunyuan-3.0', 'Nemotron-3-Super', 'Step-3.5-Flash']) {
            expect(getModelRuntimeCompatibility({ id: name }).canLoad).toBe(true);
        }
        const ids = ['minicpm-v47-1b', 'minicpm-v47-35b-a3b', 'lfm25-24b-a2b',
            'jais3-0.9b', 'jais3-3.7b', 'jais3-7b', 'jais3-32b', 'jais3-mova-36b-a4b', 'nemotron35-bolt-74b-a9b'];
        for (const id of ids) expect(getModelRuntimeCompatibility(MODEL_CATALOG.find(m => m.id === id)!, { ...prism, weeklyTextABI: 1 }).canLoad).toBe(true);
        expect(requiresWeeklyTextRuntime({ id: 'Nemotron-3.5-Super-VL-120B' })).toBe(false);
        const encoded = { url: 'https://example.invalid/NVIDIA%2DNemotron%2D3.5%2DBolt%2D74B%2DA9B.gguf' };
        expect(requiresWeeklyTextRuntime(encoded)).toBe(true);
        expect(getModelRuntimeCompatibility(encoded).canLoad).toBe(false);
        expect(getModelRuntimeCompatibility(encoded, { ...prism, weeklyTextABI: 1 }).canLoad).toBe(true);
    });
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

    it('requires the compiled Muse capability even with the pinned Prism addon', () => {
        const muse = MODEL_CATALOG.find(m => m.id === 'muse-spark-open-q2-k')!;
        expect(getModelRuntimeCompatibility(muse, prism).canLoad).toBe(false);
        expect(getModelRuntimeCompatibility(muse, prism).message).toContain('compiled Muse capability');
        expect(getModelRuntimeCompatibility(muse, { ...prism, museSparkABI: 1 }).canLoad).toBe(true);
    });

    it('enables only the complete pinned Beam path with its own compiled ABI and whole-model memory', () => {
        const beam = MODEL_CATALOG.find(m => m.id === 'beam-1.0-501b-a23b-ud-iq2-xxs')!;
        const capable = { ...prism, beamABI: 1, museSparkABI: 1 };
        expect(getModelRuntimeCompatibility(beam, prism).canLoad).toBe(false);
        expect(getModelRuntimeCompatibility(beam, { ...capable, buildType: 'prebuilt' }).canLoad).toBe(false);
        expect(getModelRuntimeCompatibility(beam, capable).canLoad).toBe(true);
        for (const change of [{ artifacts: beam.artifacts.slice(0, 1) }, { downloadBytes: 5954020 }, { sha256: '0'.repeat(64) }, { architecture: 'muse-spark' }]) {
            expect(getModelRuntimeCompatibility({ ...beam, ...change }, capable).canLoad).toBe(false);
        }
        const muse = MODEL_CATALOG.find(m => m.id === 'muse-spark-open-q2-k')!;
        expect(getModelRuntimeCompatibility({ ...muse, architecture: 'beam' }, capable).canLoad).toBe(false);
        vi.spyOn(os, 'totalmem').mockReturnValue(256 * 1024 ** 3);
        const free = vi.spyOn(memory, 'availableMemBytes').mockReturnValue(256 * 1024 ** 3);
        expect(checkMemoryForModel(beam, capable).requiredMemoryGB).toBe(208);
        expect(checkMemoryForModel(beam, capable).canLoad).toBe(true);
        free.mockReturnValue(159 * 1024 ** 3);
        expect(checkMemoryForModel(beam, capable).canLoad).toBe(false);
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
