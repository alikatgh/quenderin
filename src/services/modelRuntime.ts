/** Prism's packed ternary formats are not understood by stock llama.cpp. */
export const PRISM_LLAMA_CPP_REPO = 'PrismML-Eng/llama.cpp';
export const PRISM_LLAMA_CPP_REVISION = 'e8fd209c975c80aa7fb36a8423571ff3b1b7e955';

/** Structural so imported models can use the same gate as catalog entries. */
export interface RuntimeModelDescriptor {
    id?: string;
    filename?: string;
    quantization?: string;
    label?: string;
    url?: string;
}

/** These language towers exist in the pinned source, but are too new for arbitrary
 * bundled stock addons. This is text-only: a GGUF is not a vision projector. */
export function requiresVerifiedTextRuntime(entry: RuntimeModelDescriptor): boolean {
    const identity = `${entry.id ?? ''} ${entry.filename ?? ''} ${entry.label ?? ''} ${entry.url ?? ''}`;
    return /minicpm[-_ ]?v[-_ ]?(?:4[._-]?7|47)|lfm(?:2[._-]?5|25)[-_ ]?24b/i.test(identity);
}

export function requiresWeeklyTextRuntime(entry: RuntimeModelDescriptor): boolean {
    return /jais[-_ ]?3|nemotron[-_ ]?(?:3[._-]?5|35)/i.test(
        `${entry.id ?? ''} ${entry.filename ?? ''} ${entry.label ?? ''} ${entry.url ?? ''}`);
}

/** Metadata reported by the loaded node-llama-cpp addon, not an environment override. */
export interface NodeLlamaRuntime {
    buildType?: string;
    llamaCppRelease?: { repo?: string; release?: string };
    /** Read from the compiled addon capability function, never preferences or environment. */
    weeklyTextABI?: number;
}

export interface ModelRuntimeCompatibility {
    canLoad: boolean;
    message: string;
    runtimeRequirement?: string;
}

export function requiresPrismRuntime(entry: RuntimeModelDescriptor): boolean {
    return requiresVerifiedTextRuntime(entry) || requiresWeeklyTextRuntime(entry)
        || /^(?:PTQ1_0|PQ2_0)$/i.test(entry.quantization?.trim() ?? '')
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
    if (/muse[-_ ]?spark/i.test(`${entry.id ?? ''} ${entry.filename ?? ''} ${entry.label ?? ''}`)) {
        return {
            canLoad: false,
            runtimeRequirement: 'Muse native text adapter',
            message: 'Muse Spark Open requires the native multipart installer and text-chat adapter. This Electron/CLI build cannot install or run Muse.',
        };
    }
    if (requiresWeeklyTextRuntime(entry) && (!isPrismRuntime(runtime) || runtime?.weeklyTextABI !== 1)) {
        return {
            canLoad: false,
            runtimeRequirement: 'Verified weekly text runtime',
            message: 'Jais 3 and Nemotron 3.5 require the verified architecture backport in this build. Older Prism and stock runtimes cannot download or load these models. Support is experimental text chat only.',
        };
    }
    if (!requiresPrismRuntime(entry)) {
        return { canLoad: true, message: 'Supported by the standard desktop runtime.' };
    }
    if (isPrismRuntime(runtime)) {
        return { canLoad: true, message: 'The pinned Prism llama.cpp runtime is installed.', runtimeRequirement: 'Prism llama.cpp' };
    }
    return {
        canLoad: false,
        runtimeRequirement: 'Prism llama.cpp',
            message: `${entry.label ?? entry.id ?? entry.filename ?? 'This model'} requires the pinned Prism llama.cpp runtime. Install the experimental Prism desktop runtime before downloading or selecting this model. MiniCPM-V 4.7 support is limited to text; image and video input are unavailable.`,
    };
}

export function modelRuntimeError(compatibility: ModelRuntimeCompatibility): NodeJS.ErrnoException {
    const error = new Error(compatibility.message) as NodeJS.ErrnoException;
    error.code = 'MODEL_RUNTIME_UNSUPPORTED';
    return error;
}
