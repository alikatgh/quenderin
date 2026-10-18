import { beforeEach, describe, expect, it, vi } from 'vitest';

// These lifetime fixtures never load models, tools, embeddings or a native addon.
vi.mock('../src/services/tools/handlers.js', () => ({ executeToolCalls: vi.fn() }));
vi.mock('node-llama-cpp', () => ({ getLlama: vi.fn(), LlamaLogLevel: { disabled: 'disabled' }, LlamaModel: class {}, LlamaContext: class {}, LlamaChatSession: class {}, defineChatSessionFunction: vi.fn(), InputLookupTokenPredictor: class {} }));
const deferred = () => { let resolve!: () => void; const promise = new Promise<void>(done => { resolve = done; }); return { promise, resolve }; };
beforeEach(() => { vi.resetModules(); });

async function fixture() {
    const { LlmService } = await import('../src/services/llm.service.js');
    const { nativeWorkloads } = await import('../src/services/nativeWorkloads.js');
    return { service: new LlmService(), gate: nativeWorkloads };
}
describe('explicit process-exit native shutdown', () => {
    it('normal service cleanup disposes its own resources without interrupting or freeing another specialist backend', async () => {
        const { service, gate } = await fixture(), lease = await gate.acquire('Hy-Memory');
        const context = { dispose: vi.fn(async () => {}) }, model = { dispose: vi.fn(async () => {}) }, backend = { dispose: vi.fn(async () => {}) };
        Object.assign(service, { contextInstance: context, modelInstance: model, llamaEngine: backend });
        await service.shutdown();
        expect(context.dispose).toHaveBeenCalledOnce(); expect(model.dispose).toHaveBeenCalledOnce(); expect(backend.dispose).not.toHaveBeenCalled(); expect(lease.signal.aborted).toBe(false);
        lease(); gate.beginOrdinary()();
    });
    it('process exit aborts the active Hy lease and holds global disposal until worker and specialist cleanup join', async () => {
        const { service, gate } = await fixture(), worker = deferred(), cleanup = deferred(), aborted = deferred(), cleaning = deferred(), entered = deferred();
        const backend = { dispose: vi.fn(async () => {}) }; gate.registerBackend(backend);
        const work = gate.exclusive('Hy-Memory', undefined, async lease => {
            lease.signal.addEventListener('abort', aborted.resolve, { once: true });
            entered.resolve();
            await aborted.promise; await worker.promise; cleaning.resolve(); await cleanup.promise;
        });
        await entered.promise;
        const stopping = service.shutdown({ processExit: true });
        expect(() => gate.beginOrdinary()).toThrow('shutting down'); await aborted.promise; expect(backend.dispose).not.toHaveBeenCalled();
        worker.resolve(); await cleaning.promise; expect(backend.dispose).not.toHaveBeenCalled();
        cleanup.resolve(); await work; await stopping; await service.shutdown({ processExit: true }); expect(backend.dispose).toHaveBeenCalledOnce();
    });
    it('cancels and joins actual action prompt work plus a timed-out native initialization before disposal', async () => {
        const { service, gate } = await fixture(), cancelled = deferred(), workerJoined = deferred(), initialization = deferred();
        const context = { dispose: vi.fn(async () => {}) }, model = { dispose: vi.fn(async () => {}) }, backend = { dispose: vi.fn(async () => {}) };
        Object.assign(service, { contextInstance: context, modelInstance: model });
        const internals = service as any;
        const pendingBackend = internals.trackBackendInitialization(initialization.promise.then(() => backend));
        // Exercise the actual prompt cancellation implementation inside the actual ordinary lease wrapper.
        internals.generateActionWithLease = () => internals.promptWithTimeout({ prompt: async (_text: string, options: { signal: AbortSignal }) => {
            if (options.signal.aborted) cancelled.resolve(); else options.signal.addEventListener('abort', cancelled.resolve, { once: true });
            await cancelled.promise; await workerJoined.promise; throw new Error('Synthetic native cancellation');
        } }, 'Synthetic fixture prompt', { maxTokens: 1, temperature: 0 }, 60_000, 'Fixture action');
        const work = service.generateAction('', '', {}); const failedWork = expect(work).rejects.toThrow();
        await vi.waitFor(() => expect(internals.nativeAborts.size).toBe(1));
        const stopping = service.shutdown({ processExit: true }); await cancelled.promise;
        expect(context.dispose).not.toHaveBeenCalled(); expect(backend.dispose).not.toHaveBeenCalled();
        workerJoined.resolve(); await failedWork; await Promise.resolve(); expect(context.dispose).not.toHaveBeenCalled();
        initialization.resolve(); await pendingBackend; await stopping;
        expect(context.dispose).toHaveBeenCalledOnce(); expect(model.dispose).toHaveBeenCalledOnce(); expect(backend.dispose).toHaveBeenCalledOnce();
        expect(() => gate.beginOrdinary()).toThrow('shutting down');
    });
});
