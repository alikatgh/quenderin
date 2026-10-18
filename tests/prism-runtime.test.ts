import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({ getLlama: vi.fn() }));
vi.mock('node-llama-cpp', () => ({ getLlama: mocks.getLlama, LlamaLogLevel: { disabled: 'disabled' } }));
vi.mock('../src/utils/memory.js', () => ({ availableMemBytes: () => 64 * 1024 ** 3 }));
afterEach(() => { vi.resetModules(); mocks.getLlama.mockReset(); });
function runtime() {
    return { buildType: 'localBuild', llamaCppRelease: { repo: 'PrismML-Eng/llama.cpp', release: 'e8fd209c975c80aa7fb36a8423571ff3b1b7e955' },
        _bindings: { getQuenderinContextAbortABI: () => 1, getBlockSizeForGgmlType: () => 128, getTypeSizeForGgmlType: (id: number) => id === 142 ? 34 : 28 },
        loadModel: vi.fn(), dispose: vi.fn() };
}
describe('actual retained specialist backend and proof boundary', () => {
    it('shares one app-lifetime runtime across concurrent specialist clients without backend disposal', async () => {
        const native = runtime(); mocks.getLlama.mockResolvedValue(native);
        const { getVerifiedSpecialistRuntime, specialistRuntimeUnavailableReason } = await import('../src/services/prismRuntime.js');
        expect(specialistRuntimeUnavailableReason()).toBeNull();
        const [first, second] = await Promise.all([getVerifiedSpecialistRuntime(), getVerifiedSpecialistRuntime()]);
        expect(first.runtime).toBe(native); expect(second.runtime).toBe(native);
        expect(mocks.getLlama).toHaveBeenCalledTimes(2); // metadata-only probe + one real backend
        expect(mocks.getLlama.mock.calls[1][0]).toMatchObject({ build: 'never', gpu: false, skipDownload: true, usePrebuiltBinaries: false });
        expect(native.dispose).not.toHaveBeenCalled();
    });
    it('does not accept a caller-provided proof method or allocate a model', async () => {
        const native = runtime(); mocks.getLlama.mockResolvedValue(native);
        const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'hy-proof-boundary-'));
        try {
            const filePath = path.join(directory, 'synthetic.gguf'); fs.writeFileSync(filePath, 'GGUF');
            const { createHyMemoryInferencePort } = await import('../src/services/hyMemoryRuntime.js');
            const fake = { filePath, assertCurrent: vi.fn() };
            const port = createHyMemoryInferencePort();
            const request = { artifact: fake, prompt: '<｜hy_begin▁of▁sentence｜>test', maxOutputTokens: 512, temperature: 0,
                addBos: false, stopSequences: ['<eos:6124c78e>'], signal: new AbortController().signal } as any;
            await expect(port.generate(request)[Symbol.asyncIterator]().next()).rejects.toThrow('verified Hy-Memory artifact changed');
            expect(fake.assertCurrent).not.toHaveBeenCalled(); expect(native.loadModel).not.toHaveBeenCalled();
        } finally { fs.rmSync(directory, { recursive: true }); }
    });
    it('blocks a correctly pinned specialist addon that lacks compiled in-flight cancellation', async () => {
        const native = runtime(); (native._bindings as any).getQuenderinContextAbortABI = undefined;
        mocks.getLlama.mockResolvedValue(native);
        const { getVerifiedSpecialistRuntime, specialistRuntimeUnavailableReason } = await import('../src/services/prismRuntime.js');
        expect(specialistRuntimeUnavailableReason()).toContain('unavailable');
        await expect(getVerifiedSpecialistRuntime()).rejects.toThrow('unavailable');
        expect(native.loadModel).not.toHaveBeenCalled(); expect(native.dispose).not.toHaveBeenCalled();
    });
    it('fails closed on an old or stock addon before loading anything', async () => {
        const native = { ...runtime(), buildType: 'prebuilt' }; mocks.getLlama.mockResolvedValue(native);
        const { getVerifiedSpecialistRuntime, specialistRuntimeUnavailableReason } = await import('../src/services/prismRuntime.js');
        expect(specialistRuntimeUnavailableReason()).toContain('unavailable');
        await expect(getVerifiedSpecialistRuntime()).rejects.toThrow('unavailable');
        expect(native.loadModel).not.toHaveBeenCalled();
    });
});
