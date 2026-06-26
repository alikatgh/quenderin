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
