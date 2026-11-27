import { describe, expect, it } from 'vitest';
import { catalog, CURATED_MODELS, modelFile } from '@handy-computer/models';
import { findCatalogModel, installedModelPath, loadHandySpeechCatalog, modelDownloadUrl } from '../src/services/speech/catalog.js';

describe('Handy package catalog boundary', () => {
    it('uses exactly the pinned curated set and default files', () => {
        expect(loadHandySpeechCatalog().curatedModels).toEqual(CURATED_MODELS);
        expect(CURATED_MODELS).toHaveLength(29);
        for (const model of CURATED_MODELS) {
            const { filename, sha256, size } = modelFile(model);
            expect(sha256).toMatch(/^[0-9a-f]{64}$/);
            expect(size).toBeGreaterThan(0);
            expect(modelDownloadUrl(model)).toBe(`https://huggingface.co/${model.repository}/resolve/${model.revision}/${filename}`);
            expect(installedModelPath('speech', model)).toBe(`speech/${filename}`);
        }
        expect(findCatalogModel(catalog, 'parakeet-unified-en-0.6b')).toBe(catalog.getModel('parakeet-unified-en-0.6b'));
        expect(findCatalogModel(catalog, catalog.languageDetectionModel.id)).toBeUndefined();
    });

    it('preserves the exact sizes of the package’s English picks', () => {
        const picks = catalog.recommend(['en'], { engineVersion: '0.4.1' });
        const recommended = picks.find(p => p.roles.includes('best'))!.model;
        const accurate = picks.find(p => p.roles.includes('accurate'))!.model;
        expect([recommended.id, modelFile(recommended).size]).toEqual(['parakeet-unified-en-0.6b', 731357568]);
        expect([accurate.id, modelFile(accurate).size]).toEqual(['Qwen3-ASR-1.7B', 2185030624]);
    });

    it('rejects duplicate ids and Windows-equivalent filenames', () => {
        const model = CURATED_MODELS[0];
        expect(() => loadHandySpeechCatalog({ ...catalog, curatedModels: [model, model] })).toThrow(/duplicate/);
        const file = modelFile(model);
        const duplicate = { ...model, id: 'duplicate', files: { [model.quant]: { ...file, filename: file.filename.toUpperCase() } } };
        expect(() => loadHandySpeechCatalog({ ...catalog, curatedModels: [model, duplicate] })).toThrow(/duplicate/);
    });

    it.each([
        { repository: 'host/../../file' }, { revision: 'main' },
        { files: {} }, { role: 'vad' as const }, { minEngine: 'later' },
    ])('rejects invalid catalog pins and incompatible metadata (%j)', patch => {
        expect(() => loadHandySpeechCatalog({ ...catalog, curatedModels: [{ ...CURATED_MODELS[0], ...patch }] })).toThrow();
    });

    it('rejects filenames that escape the models folder', () => {
        const model = CURATED_MODELS[0];
        const invalid = { ...model, files: { [model.quant]: { ...modelFile(model), filename: '../other.gguf' } } };
        expect(() => installedModelPath('speech', invalid)).toThrow();
        expect(() => modelDownloadUrl(invalid)).toThrow();
    });
});
