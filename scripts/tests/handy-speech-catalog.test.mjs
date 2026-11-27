import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { accuracyGrade, catalog, CURATED_MODELS, formatBinarySize, modelFile } from '@handy-computer/models';
import {
    checkCatalog,
    HANDY_CATALOG_CANONICAL_SHA256,
    HANDY_CATALOG_SHA256,
    HANDY_COMMIT,
    REFERENCE_DIR,
} from '../sync_handy_speech_catalog.mjs';

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

test('installed catalog matches the committed Handy commit 05efc5fc digest and --check fails closed on missing --ref', () => {
    assert.match(HANDY_CATALOG_SHA256, /^[0-9a-f]{64}$/);
    assert.match(HANDY_CATALOG_CANONICAL_SHA256, /^[0-9a-f]{64}$/);
    assert.equal(checkCatalog(), 29);
    assert.equal(spawnSync(process.execPath, [script, '--check']).status, 0);

    // Explicit --ref pointing to a missing path must fail closed rather than silently passing.
    const missing = spawnSync(process.execPath, [script, '--check', '--ref', '/nonexistent-handy-ref-path']);
    assert.notEqual(missing.status, 0);
    assert.throws(() => checkCatalog('/nonexistent-handy-ref-path', { requireReference: true }), { code: 'ENOENT' });

    if (available) {
        assert.equal(fs.readFileSync(path.join(REFERENCE_DIR, 'COMMIT'), 'utf8').trim(), HANDY_COMMIT);
        const license = fs.readFileSync(path.join(REFERENCE_DIR, 'LICENSE'), 'utf8');
        assert.match(license, /^Copyright \(c\) 2025 CJ Pais$/m);
        assert.equal(spawnSync(process.execPath, [script, '--check', '--ref', REFERENCE_DIR]).status, 0);
    }
});

test('benchmark grades and wait times match pinned Handy 05efc5fc expectations', async () => {
    const pinnedBenchmarks = [
        ['parakeet-unified-en-0.6b', 1.1867088607594936, { letter: 'A', label: 'A-' }],
        ['Qwen3-ASR-1.7B', 7.343941248470013, { letter: 'A', label: 'A' }],
        ['whisper-large-v3-turbo', 9.693053311793214, { letter: 'A', label: 'A-' }],
    ];
    for (const [id, expectedWait, expectedGrade] of pinnedBenchmarks) {
        const model = CURATED_MODELS.find(entry => entry.id === id);
        assert.ok(model, `Missing curated model ${id}`);
        assert.ok(Math.abs(catalog.modelWaitSeconds(model) - expectedWait) < 1e-9);
        assert.deepEqual(catalog.languageAccuracyGrade(model, 'en'), expectedGrade);
    }
    const expectedGrades = [
        [0, 'A'], [3.23, 'A'], [5, 'B'], [8, 'B'], [10, 'C'], [17, 'C'], [20, 'D'], [30, 'F'], [55, 'F'],
    ];
    for (const [wer, letter] of expectedGrades) {
        assert.equal(accuracyGrade(wer).letter, letter);
    }
    if (available) {
        const ref = await import(pathToFileURL(path.join(REFERENCE_DIR, 'pkg/package/dist/src/index.js')).href);
        for (const model of CURATED_MODELS) {
            assert.equal(catalog.modelWaitSeconds(model), ref.modelWaitSeconds(model));
            assert.deepEqual(catalog.languageAccuracyGrade(model, 'en'), ref.languageAccuracyGrade(model, 'en'));
        }
        for (const value of [0, 3.23, 3.99, 5, 8, 10, 17, 20, 30, 55]) {
            assert.deepEqual(accuracyGrade(value), ref.accuracyGrade(value));
        }
    }
});
