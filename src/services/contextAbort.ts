/** Exact versioned addon seam. It never frees a context or the retained backend. */
interface NativeContextAbort {
    getQuenderinContextAbortABI(): number;
    resetQuenderinAbort(): void;
    requestQuenderinAbort(): void;
}
const contextTails = new WeakMap<object, Promise<void>>();

export function contextAbortRuntimeAvailable(runtime: any): boolean {
    try { return runtime?._bindings?.getQuenderinContextAbortABI() === 1; }
    catch { return false; }
}
function binding(sequence: any): NativeContextAbort {
    const native = sequence?.context?._ctx;
    try {
        if (native?.getQuenderinContextAbortABI() === 1 && typeof native.resetQuenderinAbort === 'function'
            && typeof native.requestQuenderinAbort === 'function') return native;
    } catch { /* A missing or stale native seam is unavailable, never a silent no-op. */ }
    throw new Error('The pinned native context cancellation ABI is unavailable; rebuild the verified Prism runtime.');
}
function waitForTurn(previous: Promise<void>, signal?: AbortSignal): Promise<void> {
    if (!signal) return previous;
    signal.throwIfAborted();
    let onAbort!: () => void;
    return new Promise<void>((resolve, reject) => {
        onAbort = () => reject(signal.reason);
        signal.addEventListener('abort', onAbort, { once: true });
        if (signal.aborted) onAbort();
        previous.then(resolve);
    }).finally(() => signal.removeEventListener('abort', onAbort));
}

/** The whole clear/prefill/decode operation owns this context until it settles.
 * A waiting request never resets or cancels another owner's native work. CPU
 * callbacks can interrupt an in-flight graph; GPU cancellation waits for its
 * next scheduler graph boundary. Cancellation stays set until the next owner.
 */
export async function withContextAbort<T>(sequence: any, signal: AbortSignal | undefined, work: () => Promise<T>): Promise<T> {
    signal?.throwIfAborted();
    const native = binding(sequence);
    const previous = contextTails.get(native) ?? Promise.resolve();
    let release!: () => void;
    const owned = new Promise<void>(resolve => { release = resolve; });
    const tail = previous.then(() => owned);
    contextTails.set(native, tail);
    try {
        await waitForTurn(previous, signal);
        signal?.throwIfAborted();
        native.resetQuenderinAbort();
        const onAbort = () => native.requestQuenderinAbort();
        try {
            signal?.addEventListener('abort', onAbort, { once: true });
            if (signal?.aborted) { onAbort(); signal.throwIfAborted(); }
            const value = await work();
            signal?.throwIfAborted();
            return value;
        } catch (error) {
            if (signal?.aborted) throw signal.reason;
            throw error;
        } finally {
            signal?.removeEventListener('abort', onAbort);
        }
    } finally {
        release();
        // A cancelled waiter releases its reservation immediately, while its
        // tail still waits for the current owner. Deleting before that barrier
        // resolves would let a later request reset an active cancellation flag.
        void tail.then(() => { if (contextTails.get(native) === tail) contextTails.delete(native); });
    }
}
