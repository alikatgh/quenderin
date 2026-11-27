// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/lib/models/catalog.ts and src/components/shared/SpeedBars.tsx
// at 05efc5fc180197dc0fa9d568dd9812904b723b8b. See native/speech/NOTICE.md.
import { compareEngineVersions, modelFile, modelMatchesLanguage } from '@handy-computer/models';
import type {
    HandySpeechCatalog, HandySpeechModel, SpeechAccuracyGrade, SpeechEngineCompatibility, SpeechModelSummary, SpeechSpeedLevel,
} from './types.js';

export const SPEED_CUTOFFS = [2, 3.5, 7.5, 20];

export function speedLevel(waitSeconds: number | undefined): SpeechSpeedLevel {
    return waitSeconds == null
        ? 0
        : SPEED_CUTOFFS.filter(cutoff => waitSeconds < cutoff).length as SpeechSpeedLevel;
}

export function englishGrade(catalog: HandySpeechCatalog, model: HandySpeechModel): SpeechAccuracyGrade {
    if (!modelMatchesLanguage(model, 'en')) return { letter: 'none', label: '—' };
    const grade = catalog.languageAccuracyGrade(model, 'en');
    if (!grade) return { letter: 'none', label: '?' };
    return { letter: grade.letter, label: grade.label.replace('-', '−') };
}

export function engineCompatibility(requiredVersion: string | undefined, pinnedVersion: string): SpeechEngineCompatibility {
    return !requiredVersion || compareEngineVersions(requiredVersion, pinnedVersion) <= 0 ? 'supported' : 'needs-newer-engine';
}

export function buildModelSummary(catalog: HandySpeechCatalog, model: HandySpeechModel,
    pinnedVersion: string, installed: boolean): SpeechModelSummary {
    const wait = catalog.modelWaitSeconds(model);
    return {
        model, waitSeconds: wait ?? null, englishGrade: englishGrade(catalog, model),
        speedLevel: speedLevel(wait),
        engine: {
            pinnedVersion, requiredVersion: model.minEngine ?? null,
            compatibility: engineCompatibility(model.minEngine, pinnedVersion),
        },
        installed, installedBytes: installed ? modelFile(model).size : null,
    };
}
