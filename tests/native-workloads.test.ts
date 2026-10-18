import { describe, expect, it, vi } from 'vitest';
import { NativeWorkloads } from '../src/services/nativeWorkloads.js';

describe('process-wide native memory lease', () => {
    const deferred = () => { let resolve!: () => void; const promise = new Promise<void>(done => { resolve = done; }); return { promise, resolve }; };
    it('joins idle model disposal before allocating and blocks both kinds of work throughout', async () => {
        const gate = new NativeWorkloads(); let finish!: () => void;
        const owner = { releaseForSpecialist: vi.fn(() => new Promise<void>(resolve => { finish = resolve; })) };
        gate.register(owner); const allocate = vi.fn();
        const job = gate.exclusive('Vision', undefined, async () => {
            expect(() => gate.beginOrdinary()).toThrow('Vision'); allocate();
        });
        expect(allocate).not.toHaveBeenCalled();
        expect(() => gate.beginOrdinary()).toThrow('Vision');
        await expect(gate.exclusive('Hy', undefined, async () => {})).rejects.toThrow('Vision');
        finish(); await job; expect(allocate).toHaveBeenCalledOnce(); gate.beginOrdinary()();
    });
    it('does not interrupt an active chat, agent or native load', async () => {
        const gate = new NativeWorkloads(), release = gate.beginOrdinary();
        const dispose = vi.fn(); gate.register({ releaseForSpecialist: dispose });
        await expect(gate.acquire('Vision')).rejects.toThrow('current text operation');
        expect(dispose).not.toHaveBeenCalled(); release(); release();
        (await gate.acquire('Vision'))(); expect(dispose).toHaveBeenCalledOnce();
    });
    it('releases the lease after cancellation, preparation failure and inference failure', async () => {
        const gate = new NativeWorkloads(), controller = new AbortController();
        const owner = { releaseForSpecialist: vi.fn(async () => { controller.abort(); }) };
        const unregister = gate.register(owner);
        await expect(gate.acquire('Vision', controller.signal)).rejects.toThrow();
        gate.beginOrdinary()(); unregister();
        const failOwner = { releaseForSpecialist: vi.fn(async () => { throw new Error('dispose failed'); }) };
        const remove = gate.register(failOwner);
        await expect(gate.exclusive('Vision', undefined, async () => {})).rejects.toThrow('dispose failed');
        gate.beginOrdinary()(); remove();
        await expect(gate.exclusive('Vision', undefined, async () => { throw new Error('decode failed'); })).rejects.toThrow('decode failed');
        gate.beginOrdinary()();
    });
    it('closes admission, aborts an active specialist and joins native cleanup before disposing once', async () => {
        const gate = new NativeWorkloads(), worker = deferred(), cleanup = deferred(), cleaning = deferred(), aborted = deferred();
        const dispose = vi.fn(async () => {}), backend = { dispose }; gate.registerBackend(backend); gate.registerBackend(backend);
        const work = gate.exclusive('Hy-Memory', undefined, async lease => {
            lease.signal.addEventListener('abort', aborted.resolve, { once: true });
            await aborted.promise; await worker.promise; cleaning.resolve(); await cleanup.promise;
        });
        await Promise.resolve();
        const stopping = gate.shutdown();
        expect(gate.shutdown()).toBe(stopping);
        expect(() => gate.beginOrdinary()).toThrow('shutting down'); await expect(gate.acquire('Vision')).rejects.toThrow('shutting down');
        await aborted.promise; expect(dispose).not.toHaveBeenCalled();
        worker.resolve(); await cleaning.promise; expect(dispose).not.toHaveBeenCalled();
        cleanup.resolve(); await work; await stopping; expect(dispose).toHaveBeenCalledOnce();
    });
    it('waits an acquisition already disposing ordinary resources and never starts its specialist', async () => {
        const gate = new NativeWorkloads(), disposal = deferred(), entered = deferred();
        const owner = { releaseForSpecialist: vi.fn(async () => { entered.resolve(); await disposal.promise; }), cancelNativeWork: vi.fn() };
        gate.register(owner); const backend = { dispose: vi.fn(async () => {}) }; gate.registerBackend(backend);
        const acquire = gate.acquire('Vision'); const rejected = expect(acquire).rejects.toThrow('cancelled'); await entered.promise;
        const stopping = gate.shutdown(); await Promise.resolve(); expect(owner.cancelNativeWork).toHaveBeenCalledOnce(); expect(backend.dispose).not.toHaveBeenCalled();
        disposal.resolve(); await rejected; await stopping; expect(backend.dispose).toHaveBeenCalledOnce();
    });
    it('retains admission after a bounded child error until an actual child-close join resolves', async () => {
        const gate = new NativeWorkloads(), childClosed = deferred();
        await expect(gate.exclusive('Image generation', undefined, async lease => {
            lease.joinBeforeRelease(childClosed.promise); throw new Error('bounded cancellation error');
        })).rejects.toThrow('bounded cancellation error');
        expect(() => gate.beginOrdinary()).toThrow('Image generation');
        await expect(gate.acquire('Vision')).rejects.toThrow('Image generation');
        childClosed.resolve(); await Promise.resolve(); gate.beginOrdinary()();
        const release = await gate.acquire('Vision'); release();
    });
    it('awaits trusted cancellation cleanup and fails closed on cleanup failure', async () => {
        const gate = new NativeWorkloads(), cleanup = deferred();
        const lease = await gate.acquire('Hy'); const dispose = vi.fn(async () => {}); gate.registerBackend({ dispose });
        lease.onCancel(async () => { await cleanup.promise; });
        const stopping = gate.shutdown(); lease(); await Promise.resolve(); expect(dispose).not.toHaveBeenCalled();
        cleanup.resolve(); await stopping; expect(dispose).toHaveBeenCalledOnce();
        const failing = new NativeWorkloads(), release = await failing.acquire('Hy'); failing.registerBackend({ dispose });
        release.onCancel(() => { throw new Error('native cleanup failed'); });
        const failed = failing.shutdown(); await Promise.resolve(); release(); await expect(failed).rejects.toThrow('native cleanup failed');
        expect(dispose).toHaveBeenCalledTimes(1);
    });
});
