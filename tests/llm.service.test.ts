import { describe, it, expect, vi } from 'vitest';
import { LlmService } from '../src/services/llm.service.js';

/**
 * Regression: `unloadModel()` (the "free RAM" path, also fired by the idle-timer and
 * memory-pressure auto-unload) used to set `modelInstance`/`contextInstance` to null WITHOUT
 * disposing them. node-llama-cpp models/contexts hold native memory that GC won't promptly
 * reclaim, so nulling alone freed nothing — the headline RAM-freeing operation leaked the model
 * (~GBs) on every idle cycle. These tests pin that it now disposes the native handles.
 *
 * The constructor is side-effect-free (no timers until a model loads), so the service is safe to
 * instantiate here and we inject fake handles via the private fields (TS `private` is compile-time).
 */
describe('LlmService.unloadModel — native handle disposal (leak regression)', () => {
    type Privates = { modelInstance: unknown; contextInstance: unknown };

    it('disposes the model + context (not just nulls them) so "free RAM" actually frees native memory', () => {
        const svc = new LlmService();
        const modelDispose = vi.fn();
        const contextDispose = vi.fn();
        (svc as unknown as Privates).modelInstance = { dispose: modelDispose };
        (svc as unknown as Privates).contextInstance = { dispose: contextDispose };

        svc.unloadModel();

        expect(modelDispose).toHaveBeenCalledTimes(1);
        expect(contextDispose).toHaveBeenCalledTimes(1);
        expect((svc as unknown as Privates).modelInstance).toBeNull();
        expect((svc as unknown as Privates).contextInstance).toBeNull();
    });

    it('is safe (no throw) when no model is loaded — handles already null', () => {
        const svc = new LlmService();
        expect(() => svc.unloadModel()).not.toThrow();
    });

    it('swallows a rejecting dispose() rather than crashing the unload', async () => {
        const svc = new LlmService();
        (svc as unknown as Privates).modelInstance = { dispose: () => Promise.reject(new Error('native already freed')) };
        (svc as unknown as Privates).contextInstance = { dispose: () => Promise.reject(new Error('native already freed')) };

        expect(() => svc.unloadModel()).not.toThrow();
        expect((svc as unknown as Privates).modelInstance).toBeNull();
        // Let the rejected dispose promises settle; the `.catch` must absorb them (no unhandled rejection).
        await new Promise((r) => setTimeout(r, 0));
    });
});

/**
 * Q-292: chat generation is now cancellable. `promptWithTimeout` composes an optional external
 * "stop" signal with its internal timeout and must classify the abort by CAUSE — a user stop is a
 * graceful LLM_CANCELLED (caller keeps the partial), a hang is LLM_TIMEOUT (retried). The seam is
 * `session.prompt(signal)` (the same signal the timeout already rides), so a fake session tests the
 * whole branch matrix without a model. The action path passes no signal → its behaviour is unchanged.
 */
describe('LlmService chat cancel (Q-292)', () => {
    // A fake node-llama-cpp session: rejects the moment its signal aborts, otherwise never settles
    // (so the ONLY way out is a cancel or the timeout) — unless `resolveWith` is given.
    function fakeSession(resolveWith?: string) {
        return {
            prompt: (_p: string, opts: { signal: AbortSignal }) =>
                new Promise<string>((resolve, reject) => {
                    if (resolveWith !== undefined) { resolve(resolveWith); return; }
                    if (opts.signal.aborted) { reject(new Error('aborted')); return; }
                    opts.signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
                }),
        };
    }
    const opts = { maxTokens: 8, temperature: 0.7 };
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const call = (svc: LlmService, session: unknown, timeoutMs: number, signal?: AbortSignal) =>
        (svc as any).promptWithTimeout(session, 'hi', opts, timeoutMs, 'test', signal);

    it('returns the model text on normal completion (no cancel, no timeout)', async () => {
        const svc = new LlmService();
        await expect(call(svc, fakeSession('done'), 5000)).resolves.toBe('done');
    });

    it('classifies an EXTERNAL abort as LLM_CANCELLED (a deliberate stop, not a hang)', async () => {
        const svc = new LlmService();
        const external = new AbortController();
        const p = call(svc, fakeSession(), 5000, external.signal);
        external.abort();
        await expect(p).rejects.toMatchObject({ code: 'LLM_CANCELLED' });
    });

    it('classifies the internal timer firing as LLM_TIMEOUT (unchanged behaviour)', async () => {
        const svc = new LlmService();
        await expect(call(svc, fakeSession(), 20)).rejects.toMatchObject({ code: 'LLM_TIMEOUT' });
    });

    it('honours a signal already aborted BEFORE the decode starts → LLM_CANCELLED', async () => {
        const svc = new LlmService();
        const external = new AbortController();
        external.abort();   // user hit stop while we were still setting up
        await expect(call(svc, fakeSession(), 5000, external.signal)).rejects.toMatchObject({ code: 'LLM_CANCELLED' });
    });

    it('requestChatCancel() aborts the in-flight handle', () => {
        const svc = new LlmService();
        const ac = new AbortController();
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        (svc as any).chatAbort = ac;
        svc.requestChatCancel();
        expect(ac.signal.aborted).toBe(true);
    });

    it('requestChatCancel() is a no-op when nothing is generating', () => {
        const svc = new LlmService();
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        (svc as any).chatAbort = null;
        expect(() => svc.requestChatCancel()).not.toThrow();
    });
});
