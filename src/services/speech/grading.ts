import type {
    HandySpeechModel,
    SpeechAccuracyCell,
    SpeechMachineTier,
    SpeechMethodology,
    SpeechModelResults,
} from './types.js';
import type {
    SpeechAccuracyGrade,
    SpeechDownloadPhase,
    SpeechEngineCompatibility,
    SpeechModelSummary,
    SpeechSpeedLevel,
} from './types.js';

/**
 * Handy's display bands, ported verbatim. Max error % per grade; F beyond D.
 * Keep in sync with Handy src/lib/models/catalog.ts GRADE_CEILINGS.
 */
export const GRADE_CEILINGS = { A: 5, B: 10, C: 20, D: 30 } as const;

/**
 * Handy's speed meter: four bars under 2 s, three under 3.5 s, two under
 * 7.5 s, one under 20 s, none at or above 20 s. Ported verbatim from
 * Handy src/components/shared/SpeedBars.tsx.
 */
export const SPEED_CUTOFFS = [2, 3.5, 7.5, 20] as const;

/** Handy's reference dictation length for the speed column. */
export const BENCHMARK_DICTATION_SECONDS = 30;

/** A–F letter plus the +/- modifier Handy displays, or "?" when unmeasured. */
export function accuracyGrade(_errorPercent: number): SpeechAccuracyGrade {
    throw new Error('TODO(stage2): port Handy accuracyGrade (A:5 B:10 C:20 D:30, cbrt(2) modifiers).');
}

/** English grade from the snapshot results; "?" when English was not measured. */
export function englishGrade(
    _model: HandySpeechModel,
    _results: SpeechModelResults | undefined,
): SpeechAccuracyGrade {
    throw new Error('TODO(stage2): read results[id].accuracy.en and grade it.');
}

/** Seconds after a 30 s dictation on the benchmark tier; null when unmeasured. */
export function modelWaitSeconds(
    _results: SpeechModelResults | undefined,
    _tier?: SpeechMachineTier,
): number | null {
    throw new Error('TODO(stage2): return 30 / results.performance[tier] when measured.');
}

/** 0–4 bars from the wait seconds; none for an unmeasured model. */
export function speedLevel(_waitSeconds: number | null): SpeechSpeedLevel {
    throw new Error('TODO(stage2): count SPEED_CUTOFFS the wait is under.');
}

/** Semantic version comparison for `minEngine` vs the pinned runtime. */
export function compareEngineVersions(_left: string, _right: string): -1 | 0 | 1 {
    throw new Error('TODO(stage2): compare dotted engine versions numerically.');
}

/** Whether the pinned transcribe.cpp runtime can load a model. */
export function engineCompatibility(
    _requiredVersion: string,
    _pinnedVersion: string,
): SpeechEngineCompatibility {
    throw new Error('TODO(stage2): supported when pinned >= minEngine, else needs-newer-engine.');
}

/** Compose one picker row from catalog facts + results + runtime + install state. */
export function buildModelSummary(_input: {
    readonly model: HandySpeechModel;
    readonly results: SpeechModelResults | undefined;
    readonly methodology: SpeechMethodology;
    readonly pinnedEngineVersion: string;
    readonly installedBytes: number | null;
}): SpeechModelSummary {
    throw new Error('TODO(stage2): compose a SpeechModelSummary (grade, wait, speed, engine, installed).');
}

/** UI-facing phase when a model is already present and verified. */
export const INSTALLED_PHASE: SpeechDownloadPhase = 'installed';

/** The English accuracy cell, if Handy measured it. */
export function englishCell(_results: SpeechModelResults | undefined): SpeechAccuracyCell | undefined {
    throw new Error('TODO(stage2): read results.accuracy.en.');
}
