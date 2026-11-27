import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { accuracyGrade, catalog, CURATED_MODELS, formatBinarySize, modelFile } from '@handy-computer/models';
import { checkCatalog, HANDY_COMMIT, REFERENCE_DIR } from '../sync_handy_speech_catalog.mjs';

const script = fileURLToPath(new URL('../sync_handy_speech_catalog.mjs', import.meta.url));
const available = fs.existsSync(path.join(REFERENCE_DIR, 'COMMIT'));

test('package exposes the exact 29 curated ASR pins and download sizes', () => {
    assert.equal(CURATED_MODELS.length, 29);
    for (const model of CURATED_MODELS) {
        const file = modelFile(model);
        assert.equal(model.role, 'asr');
        assert.equal(model.curated, true);
        assert.match(model.revision, /^[0-9a-f]{40}$/);
        assert.match(file.sha256, /^[0-9a-f]{64}$/);
        assert.deepEqual(file, model.files[model.quant]);
    }
    const picks = catalog.recommend(['en']);
    assert.deepEqual(picks.map(p => [p.model.id, p.roles, formatBinarySize(modelFile(p.model).size)]), [
        ['parakeet-unified-en-0.6b', ['best', 'fast'], '697 MiB'],
        ['Qwen3-ASR-1.7B', ['accurate'], '2.0 GiB'],
    ]);
});

test('installed catalog matches the reference commit and --check succeeds', { skip: !available }, () => {
    assert.equal(checkCatalog(), 29);
    assert.equal(fs.readFileSync(path.join(REFERENCE_DIR, 'COMMIT'), 'utf8').trim(), HANDY_COMMIT);
    const license = fs.readFileSync(path.join(REFERENCE_DIR, 'LICENSE'), 'utf8');
    assert.match(license, /^Copyright \(c\) 2025 CJ Pais$/m);
    assert.equal(spawnSync(process.execPath, [script, '--check', '--ref', REFERENCE_DIR]).status, 0);
});

test('benchmark functions agree with the reference package distribution', { skip: !available }, async () => {
    const ref = await import(pathToFileURL(path.join(REFERENCE_DIR, 'pkg/package/dist/src/index.js')).href);
    for (const model of CURATED_MODELS) {
        assert.equal(catalog.modelWaitSeconds(model), ref.modelWaitSeconds(model));
        assert.deepEqual(catalog.languageAccuracyGrade(model, 'en'), ref.languageAccuracyGrade(model, 'en'));
    }
    for (const value of [0, 3.23, 3.99, 5, 8, 10, 17, 20, 30, 55]) {
        assert.deepEqual(accuracyGrade(value), ref.accuracyGrade(value));
    }
});
