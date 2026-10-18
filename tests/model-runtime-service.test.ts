import fs from 'fs';
import os from 'os';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MODEL_CATALOG, modelPath } from '../src/constants.js';
import { LlmService } from '../src/services/llm.service.js';
import { PRISM_LLAMA_CPP_REPO, PRISM_LLAMA_CPP_REVISION } from '../src/services/modelRuntime.js';

const mocks = vi.hoisted(() => ({ getLlama: vi.fn(), readGgufModelIdentity: vi.fn(), availableMemBytes: vi.fn(() => 64 * 1024 ** 3) }));
vi.mock('../src/services/ggufModelIdentity.js', () => ({ readGgufModelIdentity: mocks.readGgufModelIdentity }));
vi.mock('node-llama-cpp', () => ({
    getLlama: mocks.getLlama,
    LlamaLogLevel: { disabled: 'disabled' },
    LlamaModel: class {}, LlamaContext: class {}, LlamaChatSession: class {},
    defineChatSessionFunction: vi.fn(), InputLookupTokenPredictor: class {},
}));
vi.mock('../src/utils/memory.js', () => ({ availableMemBytes: mocks.availableMemBytes }));
// Model selection never executes agent tools; keep unrelated embedding/native providers out.
vi.mock('../src/services/tools/handlers.js', () => ({ executeToolCalls: vi.fn() }));

const prism = {
    buildType: 'localBuild',
    llamaCppRelease: { repo: PRISM_LLAMA_CPP_REPO, release: PRISM_LLAMA_CPP_REVISION },
    _bindings: {
        getBlockSizeForGgmlType: (type: number) => type === 142 || type === 143 ? 128 : undefined,
        getTypeSizeForGgmlType: (type: number) => type === 142 ? 34 : type === 143 ? 28 : undefined,
    },
};
const services: LlmService[] = [];
function service(safety = false) {
    const svc = new LlmService();
    svc.updateSettings({ contextSize: 256, memorySafetyEnabled: safety });
    services.push(svc);
    return svc;
}

beforeEach(() => {
    mocks.getLlama.mockReset().mockResolvedValue({ buildType: 'prebuilt', llamaCppRelease: { repo: 'ggml-org/llama.cpp', release: 'stock' } });
    mocks.readGgufModelIdentity.mockReset().mockResolvedValue({ architecture: 'llama', modelName: 'Standard model' });
    mocks.availableMemBytes.mockReturnValue(64 * 1024 ** 3);
    vi.spyOn(os, 'totalmem').mockReturnValue(64 * 1024 ** 3);
    vi.spyOn(fs, 'existsSync').mockImplementation(file => String(file) === modelPath('bonsai2-27b'));
});
afterEach(async () => {
    for (const svc of services.splice(0)) await svc.shutdown();
    vi.restoreAllMocks();
});

describe('Prism desktop hard runtime gate', () => {
    it('keeps the working model when a standard catalog alias contains Beam metadata', async () => {
        vi.mocked(fs.existsSync).mockImplementation(file => String(file) === modelPath('qwen3-4b'));
        mocks.readGgufModelIdentity.mockResolvedValue({ architecture: 'beam', modelName: 'Renamed' });
        const svc = service();
        const loaded = svc as unknown as { modelInstance: unknown; contextInstance: unknown; loadedModelId: string };
        const model = { dispose: vi.fn() }, context = { dispose: vi.fn() };
        Object.assign(loaded, { modelInstance: model, contextInstance: context, loadedModelId: 'qwen3-14b' });
        const unload = vi.spyOn(svc, 'unloadModel');
        await expect(svc.switchModel('qwen3-4b')).rejects.toMatchObject({ code: 'MODEL_RUNTIME_UNSUPPORTED' });
        expect(unload).not.toHaveBeenCalled();
        expect(model.dispose).not.toHaveBeenCalled();
        expect(context.dispose).not.toHaveBeenCalled();
    });
    it.each([
        { architecture: 'beam', name: 'Renamed' },
        { architecture: 'hy_v3', name: 'Hy-Memory-30B-A3B' },
        { architecture: 'nemotron_h_moe', name: 'NVIDIA-Nemotron-3.5-Super-VL-120B' },
        { architecture: 'step5_vl', name: 'Renamed' },
        { architecture: 'muse-spark', name: 'Renamed' },
    ])('rejects actual unavailable GGUF identity before native allocation: %j', async general => {
        vi.mocked(fs.existsSync).mockImplementation(file => String(file) === modelPath('qwen3-4b'));
        mocks.readGgufModelIdentity.mockResolvedValue({ architecture: general.architecture, modelName: general.name });
        const engine = { loadModel: vi.fn(), dispose: vi.fn() };
        mocks.getLlama.mockResolvedValue(engine);
        const svc = service();
        (svc as unknown as { activeModelId: string }).activeModelId = 'qwen3-4b';
        await expect(svc.getModelAndContext()).rejects.toMatchObject({ code: 'MODEL_RUNTIME_UNSUPPORTED' });
        expect(engine.loadModel).not.toHaveBeenCalled();
        expect(mocks.getLlama).not.toHaveBeenCalled();
        expect(mocks.readGgufModelIdentity).toHaveBeenCalledWith(modelPath('qwen3-4b'));
    });
    it.each([
        undefined,
        { getBlockSizeForGgmlType: () => 128, getTypeSizeForGgmlType: () => undefined },
        { getBlockSizeForGgmlType: () => 128, getTypeSizeForGgmlType: () => 0 },
        { getBlockSizeForGgmlType: () => { throw new Error('missing type'); }, getTypeSizeForGgmlType: () => 28 },
    ])('rejects matching provenance without the compiled Prism type table: %j', async bindings => {
        mocks.getLlama.mockResolvedValue({ ...prism, _bindings: bindings });
        const svc = service();
        await expect(svc.checkModelRuntime(MODEL_CATALOG.find(m => m.id === 'bonsai2-27b')!)).resolves.toMatchObject({ canLoad: false });
        expect(mocks.getLlama).toHaveBeenCalledTimes(1);
        expect(mocks.getLlama.mock.calls[0][0]).toMatchObject({ dryRun: true, gpu: false, build: 'never', usePrebuiltBinaries: false });
    });

    it('rejects download before network, files, integrity checks, or the download lock changes', async () => {
        const svc = service();
        const fetch = vi.spyOn(globalThis, 'fetch');
        const mkdir = vi.spyOn(fs, 'mkdirSync');
        const stat = vi.spyOn(fs.promises, 'stat');
        await expect(svc.downloadModel('bonsai2-27b')).rejects.toMatchObject({ code: 'MODEL_RUNTIME_UNSUPPORTED' });
        expect(fetch).not.toHaveBeenCalled();
        expect(mkdir).not.toHaveBeenCalled();
        expect(stat).not.toHaveBeenCalled();
        expect((svc as unknown as { isDownloading: boolean }).isDownloading).toBe(false);
        expect(mocks.getLlama).toHaveBeenCalledWith(expect.objectContaining({ dryRun: true, gpu: false, build: 'never', usePrebuiltBinaries: false, skipDownload: true }));
    });

    it('rejects a direct switch without unloading the current model when safety is disabled', async () => {
        const svc = service();
        const unload = vi.spyOn(svc, 'unloadModel');
        const load = vi.spyOn(svc, 'getModelAndContext');
        await expect(svc.switchModel('bonsai2-27b')).rejects.toMatchObject({ code: 'MODEL_RUNTIME_UNSUPPORTED' });
        expect(unload).not.toHaveBeenCalled();
        expect(load).not.toHaveBeenCalled();
        expect(svc.getActiveModelId()).toBe(MODEL_CATALOG[0].id);
    });

    it('rejects a low-memory download with a compatible addon before side effects', async () => {
        mocks.getLlama.mockResolvedValue(prism);
        mocks.availableMemBytes.mockReturnValue(0);
        const svc = service();
        const fetch = vi.spyOn(globalThis, 'fetch');
        const mkdir = vi.spyOn(fs, 'mkdirSync');
        await expect(svc.downloadModel('bonsai2-27b')).rejects.toMatchObject({ code: 'MODEL_MEMORY_UNSAFE' });
        expect(fetch).not.toHaveBeenCalled();
        expect(mkdir).not.toHaveBeenCalled();
        expect((svc as unknown as { isDownloading: boolean }).isDownloading).toBe(false);
    });

    it('preserves a working model when a low-memory Prism switch is requested with safety disabled', async () => {
        mocks.getLlama.mockResolvedValue(prism);
        mocks.availableMemBytes.mockReturnValue(0);
        const svc = service();
        const loaded = svc as unknown as { modelInstance: unknown; contextInstance: unknown; activeModelId: string; loadedModelId: string };
        const model = { dispose: vi.fn() };
        const context = { dispose: vi.fn() };
        Object.assign(loaded, { modelInstance: model, contextInstance: context, activeModelId: 'qwen3-4b', loadedModelId: 'qwen3-4b' });
        const unload = vi.spyOn(svc, 'unloadModel');
        await expect(svc.switchModel('bonsai2-27b')).rejects.toMatchObject({ code: 'MODEL_MEMORY_UNSAFE' });
        expect(unload).not.toHaveBeenCalled();
        expect(model.dispose).not.toHaveBeenCalled();
        expect(context.dispose).not.toHaveBeenCalled();
        expect(svc.getActiveModelId()).toBe('qwen3-4b');
        expect(svc.getModelLifecycleInfo().loadedModelId).toBe('qwen3-4b');
    });

    it.each([
        [false, 'bonsai2-27b'], [true, 'bonsai2-27b'],
        [false, 'qwen3-4b'], [true, 'qwen3-4b'],
    ] as const)('excludes low-memory Prism models from pinned and fallback selection (safety=%s, pinned=%s)', async (safety, pinned) => {
        mocks.getLlama.mockResolvedValue(prism);
        mocks.availableMemBytes.mockReturnValue(0);
        const svc = service(safety);
        (svc as unknown as { activeModelId: string }).activeModelId = pinned;
        const error = await svc.getModelAndContext().catch(e => e);
        expect(error.code).toBe('MODEL_MISSING');
        expect(error.fittingModels.some((m: { id: string }) => m.id === 'bonsai2-27b')).toBe(false);
        expect(mocks.getLlama).toHaveBeenCalledTimes(1);
        expect(mocks.getLlama.mock.calls[0][0].dryRun).toBe(true);
    });

    it.each([false, true])('does not select an installed unsupported file or offer it as a missing-model hint (safety=%s)', async safety => {
        const svc = service(safety);
        (svc as unknown as { activeModelId: string }).activeModelId = 'bonsai2-27b';
        // A low-memory check also exercises the smallestDownloaded degraded fallback.
        mocks.availableMemBytes.mockReturnValue(0);
        const error = await svc.getModelAndContext().catch(e => e);
        expect(error.code).toBe('MODEL_MISSING');
        expect(error.fittingModels.some((m: { id: string }) => m.id === 'bonsai2-27b')).toBe(false);
        expect(mocks.getLlama).toHaveBeenCalledTimes(1);
        expect(mocks.getLlama.mock.calls[0][0].dryRun).toBe(true);
    });

    it('loads Bonsai through the verified local addon without a build or prebuilt fallback', async () => {
        const context = { dispose: vi.fn() };
        const model = { createContext: vi.fn().mockResolvedValue(context), dispose: vi.fn() };
        const engine = { ...prism, gpu: false, loadModel: vi.fn().mockResolvedValue(model), dispose: vi.fn() };
        mocks.getLlama.mockResolvedValueOnce(prism).mockResolvedValueOnce(engine);
        vi.spyOn(fs, 'statSync').mockReturnValue({ size: 5946648928 } as fs.Stats);
        const svc = service();
        (svc as unknown as { activeModelId: string }).activeModelId = 'bonsai2-27b';
        await expect(svc.getModelAndContext()).resolves.toMatchObject({ model, context });
        expect(engine.loadModel).toHaveBeenCalledWith(expect.objectContaining({ modelPath: modelPath('bonsai2-27b'), gpuLayers: 0 }));
        expect(mocks.getLlama.mock.calls[0][0]).toMatchObject({ dryRun: true, gpu: false });
        expect(mocks.getLlama.mock.calls[1][0]).toMatchObject({ gpu: false, build: 'never', usePrebuiltBinaries: false, skipDownload: true });
        expect(mocks.getLlama.mock.calls[1][0].dryRun).toBeUndefined();
        expect(svc.getModelLifecycleInfo().loadedModelId).toBe('bonsai2-27b');
    });

    it('rechecks the actual addon if it changes after the dry-run probe, before parsing GGUF', async () => {
        const engine = { buildType: 'prebuilt', loadModel: vi.fn(), dispose: vi.fn() };
        mocks.getLlama.mockResolvedValueOnce(prism).mockResolvedValueOnce(engine);
        const svc = service();
        (svc as unknown as { activeModelId: string }).activeModelId = 'bonsai2-27b';
        await expect(svc.getModelAndContext()).rejects.toMatchObject({ code: 'MODEL_RUNTIME_UNSUPPORTED' });
        expect(engine.loadModel).not.toHaveBeenCalled();
        expect(engine.dispose).toHaveBeenCalledTimes(1);
    });

    it('rechecks available RAM after backend initialization before allocating model weights', async () => {
        const engine = { ...prism, gpu: false, loadModel: vi.fn(), dispose: vi.fn() };
        mocks.getLlama.mockResolvedValueOnce(prism).mockImplementationOnce(async () => {
            mocks.availableMemBytes.mockReturnValue(0);
            return engine;
        });
        const svc = service();
        (svc as unknown as { activeModelId: string }).activeModelId = 'bonsai2-27b';
        await expect(svc.getModelAndContext()).rejects.toMatchObject({ code: 'MODEL_MEMORY_UNSAFE' });
        expect(engine.loadModel).not.toHaveBeenCalled();
        expect(engine.dispose).toHaveBeenCalledTimes(1);
    });

    it('rechecks native ternary types after the probe before exposing GGUF to the actual addon', async () => {
        const engine = {
            ...prism,
            _bindings: { getBlockSizeForGgmlType: () => undefined, getTypeSizeForGgmlType: () => undefined },
            loadModel: vi.fn(), dispose: vi.fn(),
        };
        mocks.getLlama.mockResolvedValueOnce(prism).mockResolvedValueOnce(engine);
        const svc = service();
        (svc as unknown as { activeModelId: string }).activeModelId = 'bonsai2-27b';
        await expect(svc.getModelAndContext()).rejects.toMatchObject({ code: 'MODEL_RUNTIME_UNSUPPORTED' });
        expect(engine.loadModel).not.toHaveBeenCalled();
        expect(engine.dispose).toHaveBeenCalledTimes(1);
    });

    it.each([false, true])('preserves standard-model override and degraded-load behavior (safety=%s)', async safety => {
        mocks.availableMemBytes.mockReturnValue(0);
        vi.mocked(fs.existsSync).mockImplementation(file => String(file) === modelPath('qwen3-4b'));
        vi.spyOn(fs, 'statSync').mockReturnValue({ size: 2400000000 } as fs.Stats);
        const context = { dispose: vi.fn() };
        const model = { createContext: vi.fn().mockResolvedValue(context), dispose: vi.fn() };
        const engine = { gpu: false, loadModel: vi.fn().mockResolvedValue(model), dispose: vi.fn() };
        mocks.getLlama.mockResolvedValue(engine);
        const svc = service(safety);
        (svc as unknown as { activeModelId: string }).activeModelId = 'qwen3-4b';
        await expect(svc.getModelAndContext()).resolves.toMatchObject({ model, context });
        expect(engine.loadModel).toHaveBeenCalled();
        expect(svc.getModelLifecycleInfo().loadedModelId).toBe('qwen3-4b');
    });
});
