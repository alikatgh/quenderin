import { describe, expect, it, vi } from 'vitest';
import { withContextAbort, contextAbortRuntimeAvailable } from '../src/services/contextAbort.js';
import { generateLocalTokens } from '../src/services/localTokenGeneration.js';

function fixture() {
    let aborted = false;
    const native = { getQuenderinContextAbortABI: () => 1,
        resetQuenderinAbort: vi.fn(() => { aborted = false; }),
        requestQuenderinAbort: vi.fn(() => { aborted = true; }) };
    const sequence = { context: { _ctx: native }, contextSize: 4096,
        clearHistory: vi.fn(async () => {}), model: { detokenize: (tokens: number[]) => String.fromCharCode(...tokens) },
        evaluate: vi.fn(async function* () { yield 65; }) };
    return { native, sequence, cancelled: () => aborted };
}
function deferred() {
    let resolve!: () => void;
    const promise = new Promise<void>(done => { resolve = done; });
    return { promise, resolve };
}
describe('native context cancellation ownership', () => {
    it('interrupts an in-flight prefill before any token is yielded', async () => {
        const f = fixture(), controller = new AbortController(), entered = deferred();
        f.sequence.evaluate.mockImplementation(async function* () {
            entered.resolve();
            // Stand in for a native graph callback while next() is pending.
            await new Promise<void>(resolve => {
                const callback = setInterval(() => { if (f.cancelled()) { clearInterval(callback); resolve(); } }, 1);
            });
            throw new Error('native decode aborted');
        });
        const emit = vi.fn();
        const work = generateLocalTokens(f.sequence, [1], { maxTokens: 4, temperature: 0, signal: controller.signal }, emit);
        await entered.promise;
        controller.abort(new Error('User stopped prefill'));
        await expect(work).rejects.toThrow('User stopped prefill');
        expect(f.native.requestQuenderinAbort).toHaveBeenCalledOnce(); expect(emit).not.toHaveBeenCalled();
    });
    it('keeps cancellation sticky until the next serialized owner resets it', async () => {
        const f = fixture(), first = new AbortController(), entered = deferred(), drain = deferred(), secondEntered = vi.fn();
        const op1 = withContextAbort(f.sequence, first.signal, async () => { entered.resolve(); await drain.promise; });
        const result1 = expect(op1).rejects.toThrow('First stopped'); await entered.promise;
        first.abort(new Error('First stopped'));
        const op2 = withContextAbort(f.sequence, undefined, async () => { secondEntered(); expect(f.cancelled()).toBe(false); });
        await Promise.resolve(); expect(secondEntered).not.toHaveBeenCalled(); expect(f.cancelled()).toBe(true);
        expect(f.native.resetQuenderinAbort).toHaveBeenCalledTimes(1);
        drain.resolve(); await result1; await op2;
        expect(f.native.resetQuenderinAbort).toHaveBeenCalledTimes(2); expect(secondEntered).toHaveBeenCalledOnce();
    });
    it('cancels a waiter without resetting or aborting the active owner or releasing its barrier', async () => {
        const f = fixture(), entered = deferred(), drain = deferred(), waiting = new AbortController();
        const active = withContextAbort(f.sequence, undefined, async () => { entered.resolve(); await drain.promise; });
        await entered.promise;
        const queued = withContextAbort(f.sequence, waiting.signal, async () => { throw new Error('must not enter'); });
        waiting.abort(new Error('Queued stopped')); await expect(queued).rejects.toThrow('Queued stopped');
        const thirdEntered = vi.fn(); const third = withContextAbort(f.sequence, undefined, async () => { thirdEntered(); });
        await Promise.resolve(); expect(thirdEntered).not.toHaveBeenCalled();
        expect(f.native.requestQuenderinAbort).not.toHaveBeenCalled(); expect(f.native.resetQuenderinAbort).toHaveBeenCalledTimes(1);
        drain.resolve(); await active; await third;
    });
    it('rejects an already-aborted signal without reset, clear or evaluation', async () => {
        const f = fixture(), controller = new AbortController(); controller.abort(new Error('Already stopped'));
        await expect(generateLocalTokens(f.sequence, [], { maxTokens: 2, temperature: 0, signal: controller.signal }, () => {})).rejects.toThrow('Already stopped');
        expect(f.native.resetQuenderinAbort).not.toHaveBeenCalled(); expect(f.sequence.clearHistory).not.toHaveBeenCalled();
        expect(f.sequence.evaluate).not.toHaveBeenCalled();
    });
    it('removes listeners after success, failure and user output stop without backend disposal', async () => {
        const f = fixture(), controller = new AbortController();
        const add = vi.spyOn(controller.signal, 'addEventListener'), remove = vi.spyOn(controller.signal, 'removeEventListener');
        await generateLocalTokens(f.sequence, [], { maxTokens: 2, temperature: 0, signal: controller.signal }, () => false);
        await expect(withContextAbort(f.sequence, controller.signal, async () => { throw new Error('work failed'); })).rejects.toThrow('work failed');
        for (const [, listener] of add.mock.calls) expect(remove.mock.calls.some(call => call[1] === listener)).toBe(true);
        controller.abort(); expect(f.native.requestQuenderinAbort).not.toHaveBeenCalled();
        expect(Object.keys(f.native)).not.toContain('dispose');
    });
    it('fails closed on missing, wrong or throwing compiled ABI and methods', async () => {
        for (const runtime of [{}, { _bindings: { getQuenderinContextAbortABI: () => 0 } }, { _bindings: { getQuenderinContextAbortABI() { throw new Error('old addon'); } } }]) expect(contextAbortRuntimeAvailable(runtime)).toBe(false);
        expect(contextAbortRuntimeAvailable({ _bindings: { getQuenderinContextAbortABI: () => 1 } })).toBe(true);
        for (const _ctx of [{}, { getQuenderinContextAbortABI: () => 1 }, { getQuenderinContextAbortABI: () => 2, resetQuenderinAbort() {}, requestQuenderinAbort() {} }]) {
            const work = vi.fn(); await expect(withContextAbort({ context: { _ctx } }, undefined, work)).rejects.toThrow('cancellation ABI'); expect(work).not.toHaveBeenCalled();
        }
    });
});
