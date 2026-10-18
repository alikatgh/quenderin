import { isBeamIdentity, isMuseIdentity, pinnedMultipartParts, type MultipartDescriptor } from './multipartModels.js';
/** Prism's packed ternary formats are not understood by stock llama.cpp. */
export const PRISM_LLAMA_CPP_REPO = 'PrismML-Eng/llama.cpp';
export const PRISM_LLAMA_CPP_REVISION = 'e8fd209c975c80aa7fb36a8423571ff3b1b7e955';

/** Structural so imported models can use the same gate as catalog entries. */
export interface RuntimeModelDescriptor extends MultipartDescriptor {
    id?: string;
    filename?: string;
    quantization?: string;
    label?: string;
    url?: string;
    architecture?: string;
    modelName?: string;
}

function identifiers(entry: RuntimeModelDescriptor): string[] {
    return [entry.id, entry.filename, entry.label, entry.url, entry.modelName].filter((s): s is string => typeof s === 'string');
}
function decodedIdentity(value: string): string {
    if (value.length > 16_384) return '';
    try { return decodeURIComponent(value); } catch { return value; }
}

/** Source availability is not a complete chat workflow. Actual GGUF identity wins over aliases. */
export function unsupportedModelWorkflowReason(entry: RuntimeModelDescriptor, allowPinnedBeam = false): string | undefined {
    if ((entry.architecture?.length ?? 0) > 256 || identifiers(entry).some(value => value.length > 16_384)) return 'The model identity is too long to validate safely.';
    const values = identifiers(entry).map(decodedIdentity);
    const keys = values.map(value => value.toLowerCase().replace(/[^a-z0-9]/g, ''));
    const arch = entry.architecture?.toLowerCase().replace(/[^a-z0-9]/g, '') ?? '';
    if (isBeamIdentity(entry) && !allowPinnedBeam && !(entry.id === 'beam-1.0-501b-a23b-ud-iq2-xxs' && pinnedMultipartParts(entry))) {
        return 'Beam requires the complete multipart installer and Harmony chat adapter. Generic chat is unavailable.';
    }
    if (keys.some(key => key.includes('hymemory'))) return 'Hy-Memory requires a specialized memory-proposal workflow with JSON validation and explicit save approval. Generic chat is unavailable.';
    if (keys.some(key => key.includes('supervl') && (key.includes('nemotron') || key.includes('120b')))) return 'Use Ask about an image with the complete Nemotron Super VL model and matching projector.';
    if (arch === 'step5' || arch === 'step5vl' || keys.some(key => key.includes('step5') && !key.includes('step35'))) return 'Use the Step 5 workflow with the pinned official CUDA gateway on your own host.';
    if (arch.includes('graniteswitch') || keys.some(key => key.includes('granite') && key.includes('switch') && key.includes('41'))) return 'Use Granite Switch 4.1 chat with a verified converted model and its provenance record.';
    if (keys.some(key => key.includes('bolte4b') || (key.includes('nemotron') && key.includes('e4b')))) return 'Nemotron Bolt E4B has no verified public artifact in this release.';
    if (keys.some(key => key.includes('nemotron35')) && !keys.some(key => /nemotron35.*bolt.*74b.*a9b/.test(key))) return 'This Nemotron 3.5 variant has not been validated. Only Bolt 74B-A9B is available as experimental text chat.';
    return undefined;
}

/** These language towers exist in the pinned source, but are too new for arbitrary
 * bundled stock addons. This is text-only: a GGUF is not a vision projector. */
export function requiresVerifiedTextRuntime(entry: RuntimeModelDescriptor): boolean {
    const identity = identifiers(entry).map(decodedIdentity).join(' ');
    return /minicpm[-_ ]?v[-_ ]?(?:4[._-]?7|47)|lfm(?:2[._-]?5|25)[-_ ]?24b/i.test(identity);
}

export function requiresWeeklyTextRuntime(entry: RuntimeModelDescriptor): boolean {
    return entry.architecture === 'k2-horizon' || identifiers(entry).some(value => {
        const key = decodedIdentity(value).toLowerCase().replace(/[^a-z0-9]/g, '');
        return key.includes('jais3') || /nemotron35.*bolt.*74b.*a9b/.test(key);
    });
}

/** Metadata reported by the loaded node-llama-cpp addon, not an environment override. */
export interface NodeLlamaRuntime {
    buildType?: string;
    llamaCppRelease?: { repo?: string; release?: string };
    /** Read from the compiled addon capability function, never preferences or environment. */
    weeklyTextABI?: number;
    beamABI?: number;
    museSparkABI?: number;
}

export interface ModelRuntimeCompatibility {
    canLoad: boolean;
    message: string;
    runtimeRequirement?: string;
}

export function requiresPrismRuntime(entry: RuntimeModelDescriptor): boolean {
    return isBeamIdentity(entry) || isMuseIdentity(entry) || requiresVerifiedTextRuntime(entry) || requiresWeeklyTextRuntime(entry)
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
    const unavailable = unsupportedModelWorkflowReason({ architecture: entry.architecture, modelName: entry.modelName },
        entry.id === 'beam-1.0-501b-a23b-ud-iq2-xxs' && !!pinnedMultipartParts(entry)) ?? unsupportedModelWorkflowReason(entry);
    if (unavailable) return { canLoad: false, message: unavailable, runtimeRequirement: 'Unavailable model workflow' };
    if (isBeamIdentity(entry) || isMuseIdentity(entry)) {
        const beam = entry.id === 'beam-1.0-501b-a23b-ud-iq2-xxs';
        if (!pinnedMultipartParts(entry) || !isPrismRuntime(runtime)
            || (beam ? runtime?.beamABI : runtime?.museSparkABI) !== 1) {
            return { canLoad: false, runtimeRequirement: 'Verified multipart text runtime',
                message: `${beam ? 'Beam' : 'Muse Spark'} requires the complete pinned catalog artifact set and compiled ${beam ? 'Beam' : 'Muse'} capability. Experimental text chat only.` };
        }
        if (entry.architecture && entry.architecture.toLowerCase().replace(/_/g, '-') !== (beam ? 'beam' : 'muse-spark')) {
            return { canLoad: false, message: 'GGUF architecture does not match the pinned multipart model.' };
        }
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
