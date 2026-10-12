/** Prism's packed ternary formats are not understood by stock llama.cpp. */
export const PRISM_LLAMA_CPP_REPO = 'PrismML-Eng/llama.cpp';
export const PRISM_LLAMA_CPP_REVISION = 'e8fd209c975c80aa7fb36a8423571ff3b1b7e955';

/** Structural so imported models can use the same gate as catalog entries. */
export interface RuntimeModelDescriptor {
    id?: string;
    filename?: string;
    quantization?: string;
    label?: string;
}

/** Metadata reported by the loaded node-llama-cpp addon, not an environment override. */
export interface NodeLlamaRuntime {
    buildType?: string;
    llamaCppRelease?: { repo?: string; release?: string };
}

export interface ModelRuntimeCompatibility {
    canLoad: boolean;
    message: string;
    runtimeRequirement?: string;
}

export function requiresPrismRuntime(entry: RuntimeModelDescriptor): boolean {
    return /^(?:PTQ1_0|PQ2_0)$/i.test(entry.quantization?.trim() ?? '')
        || /bonsai/i.test(entry.id ?? '')
        || /bonsai|PTQ1_0|PQ2_0/i.test(entry.filename ?? '');
}

export function isPrismRuntime(runtime?: NodeLlamaRuntime): boolean {
    return runtime?.buildType === 'localBuild'
        && runtime.llamaCppRelease?.repo?.toLowerCase() === PRISM_LLAMA_CPP_REPO.toLowerCase()
        && runtime.llamaCppRelease?.release?.toLowerCase() === PRISM_LLAMA_CPP_REVISION;
}

export function getModelRuntimeCompatibility(
    entry: RuntimeModelDescriptor,
    runtime?: NodeLlamaRuntime,
): ModelRuntimeCompatibility {
    if (!requiresPrismRuntime(entry)) {
        return { canLoad: true, message: 'Supported by the standard desktop runtime.' };
    }
    if (isPrismRuntime(runtime)) {
        return { canLoad: true, message: 'The pinned Prism llama.cpp runtime is installed.', runtimeRequirement: 'Prism llama.cpp' };
    }
    return {
        canLoad: false,
        runtimeRequirement: 'Prism llama.cpp',
        message: `${entry.label ?? entry.id ?? entry.filename ?? 'This model'} requires the pinned Prism llama.cpp runtime. The stock desktop runtime cannot load PTQ1_0 or PQ2_0 models. Install the experimental Prism desktop runtime before downloading or selecting this model.`,
    };
}

export function modelRuntimeError(compatibility: ModelRuntimeCompatibility): NodeJS.ErrnoException {
    const error = new Error(compatibility.message) as NodeJS.ErrnoException;
    error.code = 'MODEL_RUNTIME_UNSUPPORTED';
    return error;
}
