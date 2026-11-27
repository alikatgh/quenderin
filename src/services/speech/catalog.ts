import { catalog, modelFile } from '@handy-computer/models';
import path from 'node:path';
import type { HandySpeechCatalog, HandySpeechModel } from './types.js';

const idPattern = /^[a-z0-9][a-z0-9._-]*$/i;
const repoPattern = /^[a-z0-9][a-z0-9._-]*\/[a-z0-9][a-z0-9._-]*$/i;
const filenamePattern = /^[a-z0-9][a-z0-9._-]*\.gguf$/i;

function validatePin(model: HandySpeechModel) {
    const file = modelFile(model);
    if (!repoPattern.test(model.repository) || !/^[0-9a-f]{40}$/.test(model.revision)
        || !filenamePattern.test(file.filename) || !/^[0-9a-f]{64}$/.test(file.sha256)
        || !Number.isSafeInteger(file.size) || file.size <= 0) {
        throw new Error(`Invalid Handy artifact pin for ${model.id}.`);
    }
    return file;
}

/** The package owns the schema. Validate the pinned files at our disk and network boundary. */
export function loadHandySpeechCatalog(source: HandySpeechCatalog = catalog): HandySpeechCatalog {
    const ids = new Set<string>();
    const filenames = new Set<string>();
    for (const model of source.curatedModels) {
        const filename = validatePin(model).filename.toLowerCase();
        if (model.role !== 'asr' || !model.curated || !idPattern.test(model.id) || ids.has(model.id)
            || filenames.has(filename) || (model.minEngine && !/^\d+\.\d+\.\d+$/.test(model.minEngine))) {
            throw new Error(`Invalid or duplicate curated Handy model ${model.id}.`);
        }
        ids.add(model.id);
        filenames.add(filename);
    }
    if (!ids.size) throw new Error('The Handy catalog has no curated speech models.');
    return source;
}

export function findCatalogModel(catalog: HandySpeechCatalog, modelId: string): HandySpeechModel | undefined {
    return catalog.curatedModels.find(model => model.id === modelId);
}

export function modelDownloadUrl(model: HandySpeechModel): string {
    return `https://huggingface.co/${model.repository}/resolve/${model.revision}/${validatePin(model).filename}`;
}

export function installedModelPath(modelsDir: string, model: HandySpeechModel): string {
    return path.join(modelsDir, validatePin(model).filename);
}
