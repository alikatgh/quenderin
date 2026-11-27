import { modelFile } from '@handy-computer/models';
import os from 'node:os';
import path from 'node:path';
import type { SpeechRouteDependencies } from '../../routes/speech.js';
import { HexSpeechAdapter, type SpeechModelManifest } from '../hexSpeechAdapter.js';
import { findCatalogModel, loadHandySpeechCatalog } from './catalog.js';
import { fetchSpeechArtifact, speechDownloadFs, SpeechDownloadManager } from './downloadManager.js';
import { SpeechSettingsStore } from './speechSettings.js';
import { transcribeSpeech } from './transcribe.js';
import type { HandySpeechModel } from './types.js';

function speechManifest(model: HandySpeechModel): SpeechModelManifest {
    const file = modelFile(model);
    return {
        id: model.id, label: model.name, engine: 'transcribe.cpp',
        architecture: model.family, variant: model.quant,
        repo: model.repository, revision: model.revision, filename: file.filename, localFilename: file.filename,
        bytes: file.size, sha256: file.sha256, languages: [...model.languages],
        acceptsLanguageHint: model.languages.length > 1,
        supportsLanguageDetection: model.capabilities.languageDetection,
        streams: model.capabilities.streaming, vocabularyUse: 'none', license: model.license, access: 'public',
    };
}

export function createDashboardSpeech(): SpeechRouteDependencies {
    const catalog = loadHandySpeechCatalog();
    const reference = new HexSpeechAdapter();
    const { engineVersion: pinnedEngineVersion, bounds: { maxAudioBytes } } = reference.runtimeLock;
    const adapter = new HexSpeechAdapter({
        runtimeLock: reference.runtimeLock,
        catalog: { ...reference.catalog, models: catalog.curatedModels.map(speechManifest) },
    });
    const modelsDir = path.join(os.homedir(), '.quenderin', 'models', 'speech');
    const settings = new SpeechSettingsStore({ knownModel: id => !!findCatalogModel(catalog, id) });
    const downloads = new SpeechDownloadManager({
        catalog, modelsDir, pinnedEngineVersion, fetchImpl: fetchSpeechArtifact, fs: speechDownloadFs,
    });
    return {
        catalog, pinnedEngineVersion, maxAudioBytes, downloads, settings,
        transcribe: (request, signal) => transcribeSpeech({
            catalog, pinnedEngineVersion, modelsDir, adapter, maxAudioBytes, signal,
        }, request),
    };
}
