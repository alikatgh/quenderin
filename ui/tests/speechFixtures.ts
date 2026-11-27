import { catalog, CURATED_MODELS, modelFile } from '@handy-computer/models';
import { vi } from 'vitest';
import type { SpeechSetup } from '../src/lib/speech/useSpeechSetup.js';
import type { SpeechDownloadSnapshot, SpeechModelListResponse, SpeechSettingsResponse } from '../src/lib/speech/types.js';

export const recommended = 'parakeet-unified-en-0.6b';
export const accurate = 'Qwen3-ASR-1.7B';

export const catalogFixture: SpeechModelListResponse = {
    runtimeEngineVersion: '0.4.1', recommendedModelId: recommended, accurateModelId: accurate, methodology: catalog.methodology,
    models: CURATED_MODELS.map(model => ({
        model, englishGrade: { letter: 'A', label: 'A−' },
        speedLevel: model.id === recommended ? 4 : 2, waitSeconds: catalog.modelWaitSeconds(model) ?? null,
        installed: false, installedBytes: null,
        engine: { pinnedVersion: '0.4.1', requiredVersion: model.minEngine ?? null, compatibility: 'supported' },
    })),
};

export const snapshot = (phase: SpeechDownloadSnapshot['phase'], patch: Partial<SpeechDownloadSnapshot> = {}): SpeechDownloadSnapshot => ({
    modelId: recommended, phase, downloadedBytes: 1024 ** 2 * 100, totalBytes: modelFile(catalog.getModel(recommended)!).size,
    percent: 14.34, bytesPerSecond: null, etaSeconds: null, error: null, updatedAt: '2026-11-27T00:00:00.000Z', ...patch,
});

export function speechFixture(patch: Partial<SpeechSetup> = {}) {
    const settings: SpeechSettingsResponse = {
        voiceEnabled: false, modelId: null, autoSend: false, updatedAt: '2026-11-27T00:00:00.000Z',
    };
    return {
        catalog: catalogFixture, settings, loadError: null, load: vi.fn(async () => {}),
        refreshDownload: vi.fn(), updateSettings: vi.fn(async () => {}),
        downloads: { snapshots: {}, refresh: vi.fn(async () => {}), run: vi.fn(async () => {}) },
        ...patch,
    } satisfies SpeechSetup;
}
