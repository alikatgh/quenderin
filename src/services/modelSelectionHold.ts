/**
 * Explicit model selection, adapted from Turnstone 1.9.
 *
 * A conversation that has named a model keeps that name. A missing, unreadable,
 * incompatible, or memory-blocked selection fails with a reason. It is never
 * swapped for a different catalog row. No explicit choice still lets the
 * existing first-run recommender run.
 *
 * This function does not read the disk, load a runtime, or run a model.
 * `experimental-source` is source integration only: not tested inference and
 * not store availability.
 */

export type ModelAvailability = 'present' | 'missing' | 'unreadable' | 'incompatible' | 'blocked';
export type ModelEvidence = 'ordinary' | 'experimental-source';

export interface ModelHoldInput {
    explicitModelId: string | null;
    availability: ModelAvailability;
    evidence: ModelEvidence;
}

export type ModelHoldDecision =
    | { kind: 'recommend' }
    | { kind: 'use'; modelId: string; evidence: ModelEvidence; notice: string }
    | { kind: 'wait'; modelId: string; availability: Exclude<ModelAvailability, 'present'>; message: string };

export const EXPERIMENTAL_SOURCE_NOTICE =
    'Experimental engine support. This selection is source integration, not tested inference, and it is not a store release.';

export function modelHoldMessage(modelId: string, availability: Exclude<ModelAvailability, 'present'>): string {
    const why = availability === 'missing'
        ? 'is not on this device'
        : availability === 'unreadable'
            ? 'cannot be read'
            : availability === 'incompatible'
                ? 'does not run in this build'
                : 'does not fit the current memory gate';
    return `"${modelId}" ${why}. This choice stays selected and was not replaced. Choose another model to continue.`;
}

export function decideModelHold(input: ModelHoldInput): ModelHoldDecision {
    const modelId = input.explicitModelId?.trim() ?? '';
    if (!modelId) return { kind: 'recommend' };
    if (input.availability === 'present') {
        return {
            kind: 'use',
            modelId,
            evidence: input.evidence,
            notice: input.evidence === 'experimental-source' ? EXPERIMENTAL_SOURCE_NOTICE : '',
        };
    }
    const message = modelHoldMessage(modelId, input.availability);
    return {
        kind: 'wait',
        modelId,
        availability: input.availability,
        message: input.evidence === 'experimental-source' ? `${message} ${EXPERIMENTAL_SOURCE_NOTICE}` : message,
    };
}

export type ExplicitSelection =
    | { action: 'fallback' }
    | { action: 'use'; notice: string; degraded: boolean }
    | { action: 'wait'; message: string };

/** Map facts the caller already gathered. `explicit: false` keeps the recommender. */
export function explicitSelection(input: {
    explicit: boolean;
    modelId: string;
    catalogHit: boolean;
    runtimeCanLoad: boolean;
    filePresent: boolean;
    memoryCanLoad: boolean;
    experimentalSource: boolean;
}): ExplicitSelection {
    if (!input.explicit) return { action: 'fallback' };
    const evidence: ModelEvidence = input.experimentalSource ? 'experimental-source' : 'ordinary';
    const availability: ModelAvailability = !input.catalogHit
        ? 'unreadable'
        : !input.runtimeCanLoad
            ? 'incompatible'
            : !input.filePresent
                ? 'missing'
                : !input.memoryCanLoad && input.experimentalSource
                    ? 'blocked'
                    : 'present';
    const decision = decideModelHold({ explicitModelId: input.modelId, availability, evidence });
    if (decision.kind === 'wait') return { action: 'wait', message: decision.message };
    if (decision.kind === 'use') {
        return { action: 'use', notice: decision.notice, degraded: !input.memoryCanLoad };
    }
    return { action: 'fallback' };
}
