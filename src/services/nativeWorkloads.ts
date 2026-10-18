export interface OrdinaryModelOwner {
    releaseForSpecialist(): Promise<void>;
    cancelNativeWork?(): void;
    shutdownNativeWork?(): Promise<void>;
}
export interface NativeWorkloadLease {
    (): void;
    readonly signal: AbortSignal;
    onCancel(callback: () => void | Promise<void>): () => void;
    joinBeforeRelease(joined: Promise<void>): void;
}

/** One process-wide memory lease. Idle mmap weights must be released before measuring free RAM. */
export class NativeWorkloads {
    private ordinary = 0;
    private specialist: string | undefined;
    private activeLease: NativeWorkloadLease | undefined;
    private specialistAbort: AbortController | undefined;
    private closed = false;
    private shutdownTask: Promise<void> | undefined;
    private ownerCounts = new WeakMap<OrdinaryModelOwner, number>();
    private waiters = new Set<() => void>();
    private backends = new Set<{ dispose(): void | Promise<void> }>();
    private knownBackends = new WeakSet<object>();
    private cancellationTasks = new Set<Promise<void>>();
    private cancellationFailure: { error: unknown } | undefined;
    private releasedLeases = new WeakSet<NativeWorkloadLease>();
    private owners = new Set<WeakRef<OrdinaryModelOwner>>();
    register(owner: OrdinaryModelOwner): () => void {
        if (this.closed) throw new Error('The local engine is shutting down.');
        const reference = new WeakRef(owner); this.owners.add(reference);
        return () => this.owners.delete(reference);
    }
    registerBackend(backend: { dispose(): void | Promise<void> }): void {
        if (!backend || typeof backend.dispose !== 'function') throw new Error('Invalid native backend disposal handle.');
        if (!this.knownBackends.has(backend)) { this.knownBackends.add(backend); this.backends.add(backend); }
    }
    private changed(): void { const pending = this.waiters; this.waiters = new Set(); pending.forEach(resolve => resolve()); }
    private async waitFor(test: () => boolean): Promise<void> { while (!test()) await new Promise<void>(resolve => { this.waiters.add(resolve); }); }
    async joinOwner(owner: OrdinaryModelOwner): Promise<void> { await this.waitFor(() => !this.ownerCounts.get(owner)); }
    beginOrdinary(owner?: OrdinaryModelOwner): () => void {
        if (this.closed) throw new Error('The local engine is shutting down.');
        if (this.specialist) throw new Error(`${this.specialist} is using the local engine. Finish or cancel it before starting text work.`);
        this.ordinary++;
        if (owner) this.ownerCounts.set(owner, (this.ownerCounts.get(owner) ?? 0) + 1);
        let released = false;
        return () => { if (!released) { released = true; this.ordinary--; if (owner) this.ownerCounts.set(owner, this.ownerCounts.get(owner)! - 1); this.changed(); } };
    }
    async acquire(label: string, signal?: AbortSignal): Promise<NativeWorkloadLease> {
        if (this.closed) throw new Error('The local engine is shutting down.');
        if (signal?.aborted) throw new Error(`${label} operation cancelled.`);
        if (this.specialist) throw new Error(`${this.specialist} is already running in the local engine.`);
        if (this.ordinary) throw new Error('Finish or stop the current text operation before starting another local model.');
        this.specialist = label;
        const controller = new AbortController(); this.specialistAbort = controller;
        const abort = () => controller.abort();
        signal?.addEventListener('abort', abort, { once: true });
        let released = false, finished = false, joinFailed = false;
        const joins = new Set<Promise<void>>();
        const callbacks = new Set<() => void | Promise<void>>();
        const invoke = (callback: () => void | Promise<void>) => {
            const task = Promise.resolve().then(callback);
            this.cancellationTasks.add(task);
            void task.then(() => { this.cancellationTasks.delete(task); }, error => { this.cancellationFailure = { error }; this.cancellationTasks.delete(task); });
        };
        const cancel = () => { const pending = [...callbacks]; callbacks.clear(); pending.forEach(invoke); };
        controller.signal.addEventListener('abort', cancel, { once: true });
        const finish = () => {
            if (!released || finished || joins.size || joinFailed) return; finished = true;
            signal?.removeEventListener('abort', abort); controller.signal.removeEventListener('abort', cancel); callbacks.clear();
            if (this.specialistAbort === controller) { this.activeLease = undefined; this.specialistAbort = undefined; this.specialist = undefined; }
            this.changed();
        };
        const release: NativeWorkloadLease = Object.assign(() => {
            if (released) return; released = true; this.releasedLeases.add(release); finish();
        }, { signal: controller.signal, onCancel: (callback: () => void | Promise<void>) => {
            if (released) throw new Error('The local model memory lease is no longer active.');
            if (controller.signal.aborted) invoke(callback); else callbacks.add(callback);
            return () => { callbacks.delete(callback); };
        }, joinBeforeRelease: (joined: Promise<void>) => {
            if (released) throw new Error('The local model memory lease is no longer active.');
            if (joins.has(joined)) return; joins.add(joined);
            void joined.then(() => { joins.delete(joined); finish(); }, error => {
                // A rejected "join" does not prove native exit. Preserve admission until process exit.
                joins.delete(joined); joinFailed = true; this.cancellationFailure = { error }; this.changed();
            });
        } });
        try {
            for (const reference of this.owners) {
                const owner = reference.deref();
                if (owner) await owner.releaseForSpecialist();
                else this.owners.delete(reference);
            }
            if (controller.signal.aborted || this.closed) throw new Error(`${label} operation cancelled.`);
            this.activeLease = release;
            return release;
        } catch (error) { release(); throw error; }
    }
    assertHeld(lease: () => void, label: string): void {
        if (this.activeLease !== lease || this.specialist !== label || this.releasedLeases.has(lease as NativeWorkloadLease)) throw new Error('The local model memory lease is no longer active.');
    }
    async exclusive<T>(label: string, signal: AbortSignal | undefined, work: (lease: NativeWorkloadLease) => Promise<T>): Promise<T> {
        const release = await this.acquire(label, signal);
        try { return await work(release); } finally { release(); }
    }
    /** Process exit only: no backend is disposed until every admitted native worker has joined. */
    shutdown(): Promise<void> {
        if (this.shutdownTask) return this.shutdownTask;
        this.closed = true;
        const owners = [...this.owners].flatMap(reference => { const owner = reference.deref(); return owner ? [owner] : []; });
        this.shutdownTask = Promise.resolve().then(async () => {
            this.specialistAbort?.abort();
            for (const owner of owners) { try { owner.cancelNativeWork?.(); } catch (error) { this.cancellationFailure = { error }; } }
            await this.waitFor(() => this.ordinary === 0 && this.specialist === undefined);
            while (this.cancellationTasks.size) await Promise.allSettled([...this.cancellationTasks]);
            if (this.cancellationFailure) throw this.cancellationFailure.error;
            for (const owner of owners) {
                if (owner.shutdownNativeWork) await owner.shutdownNativeWork();
                else await owner.releaseForSpecialist();
            }
            for (const backend of this.backends) await backend.dispose();
            this.backends.clear();
        });
        return this.shutdownTask;
    }
}
export const nativeWorkloads = new NativeWorkloads();
