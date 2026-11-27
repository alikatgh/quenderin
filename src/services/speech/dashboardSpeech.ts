import { modelFile } from '@handy-computer/models';
import os from 'node:os';
import path from 'node:path';
import type { SpeechRouteDependencies } from '../../routes/speech.js';
import { HexSpeechAdapter, type SpeechModelManifest } from '../hexSpeechAdapter.js';
import { findCatalogModel, loadHandySpeechCatalog } from './catalog.js';
import {
    fetchSpeechArtifact, speechDownloadFs, SpeechDownloadManager,
    type SpeechDownloadFetch, type SpeechDownloadFileSystem,
} from './downloadManager.js';
import { SpeechSettingsStore } from './speechSettings.js';
import { transcribeSpeech } from './transcribe.js';
import type { HandySpeechCatalog, HandySpeechModel } from './types.js';

export interface CreateDashboardSpeechOptions {
    readonly catalog?: HandySpeechCatalog;
    readonly modelsDir?: string;
    readonly settingsFilePath?: string;
    readonly bundledRuntimePath?: string;
    readonly fetchImpl?: SpeechDownloadFetch;
    readonly fs?: SpeechDownloadFileSystem;
    readonly uploadTimeoutMs?: number;
}

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

export function createDashboardSpeech(options: CreateDashboardSpeechOptions = {}): SpeechRouteDependencies {
    const catalog = loadHandySpeechCatalog(options.catalog);
    const reference = new HexSpeechAdapter();
    const { engineVersion: pinnedEngineVersion, bounds: { maxAudioBytes } } = reference.runtimeLock;
    const adapter = new HexSpeechAdapter({
        runtimeLock: reference.runtimeLock,
        catalog: { ...reference.catalog, models: catalog.curatedModels.map(speechManifest) },
        bundledRuntimePath: options.bundledRuntimePath,
    });
    const modelsDir = options.modelsDir ?? path.join(os.homedir(), '.quenderin', 'models', 'speech');
    const settings = new SpeechSettingsStore({
        filePath: options.settingsFilePath,
        knownModel: id => !!findCatalogModel(catalog, id),
    });
    const downloads = new SpeechDownloadManager({
        catalog, modelsDir, pinnedEngineVersion,
        fetchImpl: options.fetchImpl ?? fetchSpeechArtifact,
        fs: options.fs ?? speechDownloadFs,
    });
    return {
        catalog, pinnedEngineVersion, maxAudioBytes, uploadTimeoutMs: options.uploadTimeoutMs, downloads, settings,
        transcribe: (request, signal) => transcribeSpeech({
            catalog, pinnedEngineVersion, modelsDir, adapter, maxAudioBytes, signal,
        }, request),
    };
}
