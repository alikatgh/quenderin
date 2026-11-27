import { fileURLToPath } from 'node:url';
import path from 'node:path';
import type {
    HandySpeechCatalog,
    HandySpeechModel,
} from './types.js';

export interface LoadHandyCatalogOptions {
    /** Explicit snapshot path (tests, packaged overrides). */
    readonly snapshotPath?: string;
}

/**
 * Candidate locations for shared/handy-speech-catalog.json, most-specific first:
 *   1. an explicit path,
 *   2. the repo/asar layout relative to this module,
 *   3. process.cwd()/shared (dev + `npm test`).
 */
export function handyCatalogPaths(explicitPath?: string): readonly string[] {
    const candidates = [
        explicitPath,
        fileURLToPath(new URL('../../../shared/handy-speech-catalog.json', import.meta.url)),
        path.join(process.cwd(), 'shared', 'handy-speech-catalog.json'),
    ];
    return [...new Set(candidates.filter((candidate): candidate is string => typeof candidate === 'string'))];
}

/**
 * Validate the generated snapshot before any of it reaches the UI. The snapshot
 * is generated, not hand-edited: reject duplicate ids, non-ASR rows, missing
 * files/results and non-HTTPS download URLs with a concrete error.
 */
export function parseHandySpeechCatalog(_raw: unknown): HandySpeechCatalog {
    throw new Error('TODO(stage2): validate shared/handy-speech-catalog.json (29 curated ASR rows, results, URLs).');
}

/** Load and validate the pinned Handy catalog snapshot. */
export function loadHandySpeechCatalog(_options: LoadHandyCatalogOptions = {}): HandySpeechCatalog {
    throw new Error('TODO(stage2): read shared/handy-speech-catalog.json from handyCatalogPaths() and parse it.');
}

/** Look up one curated ASR model; undefined for an unknown id. */
export function findCatalogModel(
    _catalog: HandySpeechCatalog,
    _modelId: string,
): HandySpeechModel | undefined {
    throw new Error('TODO(stage2): find a catalog model by id.');
}

/** The pinned Hugging Face URL for the model's default-quant file. */
export function modelDownloadUrl(_model: HandySpeechModel): string {
    throw new Error('TODO(stage2): return model.file.url after validating it.');
}

/** Path where the installed GGUF lives, under the app's speech model directory. */
export function installedModelPath(_modelsDir: string, _model: HandySpeechModel): string {
    throw new Error('TODO(stage2): join modelsDir with the catalog filename.');
}
