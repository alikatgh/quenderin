import { BEAM_ARTIFACTS } from '../beamModelArtifacts.js';
import { MUSE_SPARK_ARTIFACTS } from '../museModelArtifacts.js';

export interface ModelArtifact { readonly filename: string; readonly url: string; readonly sha256: string; readonly downloadBytes: number }
export interface MultipartDescriptor {
    id?: string; filename?: string; url?: string; sha256?: string | null; downloadBytes?: number;
    artifacts?: readonly ModelArtifact[]; quantization?: string; paramsBillions?: number;
}

/** An alias or a first-shard hash never grants permission to load a split model. */
export function pinnedMultipartParts(model: MultipartDescriptor): readonly ModelArtifact[] | undefined {
    const parts = model.id === 'beam-1.0-501b-a23b-ud-iq2-xxs' ? BEAM_ARTIFACTS
        : model.id === 'muse-spark-open-q2-k' ? MUSE_SPARK_ARTIFACTS : undefined;
    if (!parts || model.filename !== parts[0].filename || model.url !== parts[0].url
        || model.sha256 !== parts[0].sha256 || model.downloadBytes !== parts.reduce((sum, p) => sum + p.downloadBytes, 0)
        || model.artifacts?.length !== parts.length
        || !parts.every((part, index) => { const actual = model.artifacts?.[index]; return actual && actual.filename === part.filename
            && actual.url === part.url && actual.sha256 === part.sha256 && actual.downloadBytes === part.downloadBytes; })
        || model.paramsBillions !== (parts === BEAM_ARTIFACTS ? 501 : 816)
        || model.quantization !== (parts === BEAM_ARTIFACTS ? 'UD-IQ2_XXS' : 'Q2_K')) return undefined;
    return parts;
}

export function isBeamIdentity(model: { architecture?: string; id?: string; filename?: string; label?: string; url?: string; modelName?: string }): boolean {
    return model.architecture?.toLowerCase() === 'beam' || [model.id, model.filename, model.label, model.url, model.modelName].some(value => {
        if (!value || value.length > 16_384) return false;
        try { value = decodeURIComponent(value); } catch { /* identity remains untrusted */ }
        return /(?:^|[^a-z0-9])beam(?:[0-9]|[^a-z0-9]|$)/i.test(value);
    });
}

export function isMuseIdentity(model: { architecture?: string; id?: string; filename?: string; label?: string; url?: string; modelName?: string }): boolean {
    return [model.architecture, model.id, model.filename, model.label, model.url, model.modelName]
        .some(value => { if (!value || value.length > 16_384) return false; try { value = decodeURIComponent(value); } catch { /* Match the original untrusted identity. */ } return /muse[-_ ]?spark/i.test(value); });
}
