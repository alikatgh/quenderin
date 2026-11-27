#!/usr/bin/env node
// The installed package is the runtime catalog. Check it against the pinned Handy source.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { catalog, CURATED_MODELS } from '@handy-computer/models';

export const HANDY_COMMIT = '05efc5fc180197dc0fa9d568dd9812904b723b8b';
export const PACKAGE_VERSION = '0.2.3';
export const REFERENCE_DIR = process.env.HANDY_REF || '/workspace/handy-ref';

export function checkCatalog(reference = REFERENCE_DIR) {
    const require = createRequire(import.meta.url);
    const bundled = require.resolve('@handy-computer/models/catalog.json');
    const manifest = JSON.parse(readFileSync(path.join(path.dirname(bundled), 'package.json'), 'utf8'));
    const expected = JSON.parse(readFileSync(path.join(reference, 'src-tauri/src/catalog/catalog.json'), 'utf8'));
    assert.equal(manifest.version, PACKAGE_VERSION);
    assert.equal(manifest.license, 'MIT');
    assert.equal(readFileSync(path.join(reference, 'COMMIT'), 'utf8').trim(), HANDY_COMMIT);
    assert.deepEqual(catalog.data, expected);
    assert.deepEqual(CURATED_MODELS, expected.models.filter(model => model.role === 'asr' && model.curated));
    return CURATED_MODELS.length;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    const args = process.argv.slice(2);
    if (args[0] !== '--check' || (args.length !== 1 && !(args.length === 3 && args[1] === '--ref'))) {
        console.error('Usage: node scripts/sync_handy_speech_catalog.mjs --check [--ref <handy-root>]');
        process.exitCode = 1;
    } else {
        try {
            console.log(`Handy package matches the pinned catalog (${checkCatalog(args[2])} curated ASR models).`);
        } catch (error) {
            // Avoid printing the full catalog on a deep comparison error.
            console.error(`Handy catalog check failed (${error.code ?? error.name}).`);
            process.exitCode = 1;
        }
    }
}
