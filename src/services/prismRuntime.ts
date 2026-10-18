import { isPrismRuntime } from './modelRuntime.js';
import { contextAbortRuntimeAvailable } from './contextAbort.js';
import { nativeWorkloads } from './nativeWorkloads.js';

let bindings: any;
// node-llama-cpp owns one process-wide native backend. Keep this verified engine alive
// until process shutdown; each proposal disposes only its own model/context.
let retainedRuntime: Promise<any> | undefined;
let unavailable: string | null = 'The verified Prism specialist runtime is unavailable in this build.';
const localOptions = { build: 'never', gpu: false, usePrebuiltBinaries: false, skipDownload: true, progressLogs: false } as const;
function verified(runtime: any): boolean {
    try {
        return isPrismRuntime(runtime) && contextAbortRuntimeAvailable(runtime) && runtime._bindings.getBlockSizeForGgmlType(142) === 128
            && runtime._bindings.getTypeSizeForGgmlType(142) === 34
            && runtime._bindings.getBlockSizeForGgmlType(143) === 128
            && runtime._bindings.getTypeSizeForGgmlType(143) === 28;
    } catch { return false; }
}
try {
    bindings = await import('node-llama-cpp');
    // Same no-build/no-download metadata probe as the ordinary LlmService. No model allocation.
    const probe = await bindings.getLlama({ ...localOptions, dryRun: true, logLevel: bindings.LlamaLogLevel.disabled });
    if (verified(probe)) unavailable = null;
} catch { /* Exact runtime detection fails closed, including optional addon load errors. */ }

/** App-lifetime backend; callers own and dispose only their model/context allocations. */
export function specialistRuntimeUnavailableReason(): string | null { return unavailable; }
export async function getVerifiedSpecialistRuntime(): Promise<{ runtime: any; bindings: any }> {
    if (unavailable || !bindings) throw new Error(unavailable ?? 'Specialist runtime unavailable.');
    const runtime = await (retainedRuntime ??= bindings.getLlama({ ...localOptions, logLevel: bindings.LlamaLogLevel.disabled }));
    nativeWorkloads.registerBackend(runtime);
    if (!verified(runtime)) throw new Error('The specialist runtime changed; rebuild the pinned Prism runtime.');
    return { runtime, bindings };
}
