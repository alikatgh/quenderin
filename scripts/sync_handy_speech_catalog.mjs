#!/usr/bin/env node
// The installed package is the runtime catalog. Check it against the pinned Handy source
// and the committed SHA-256 digests derived from Handy commit 05efc5fc180197dc0fa9d568dd9812904b723b8b.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { catalog, CURATED_MODELS } from '@handy-computer/models';

export const HANDY_COMMIT = '05efc5fc180197dc0fa9d568dd9812904b723b8b';
export const PACKAGE_VERSION = '0.2.3';
export const REFERENCE_DIR = process.env.HANDY_REF || '/workspace/handy-ref';
// SHA-256 of Handy src-tauri/src/catalog/catalog.json at HANDY_COMMIT (raw bytes and canonical JSON).
export const HANDY_CATALOG_SHA256 = '63716f820650bd963e9954577f1136e64328d0e813a1b1dab6adb36ef795b4f5';
export const HANDY_CATALOG_CANONICAL_SHA256 = '7954160ada4e3d255fc17360ec3d27dad91e1a955bb2ffd19aa3a9437acf8fe5';

function sha256(data) {
    return createHash('sha256').update(data).digest('hex');
}

export function checkCatalog(reference = REFERENCE_DIR, { requireReference = false } = {}) {
    const require = createRequire(import.meta.url);
    const bundled = require.resolve('@handy-computer/models/catalog.json');
    const manifest = JSON.parse(readFileSync(path.join(path.dirname(bundled), 'package.json'), 'utf8'));
    const bundledRaw = readFileSync(bundled);
    assert.equal(manifest.version, PACKAGE_VERSION);
    assert.equal(manifest.license, 'MIT');
    assert.equal(sha256(bundledRaw), HANDY_CATALOG_SHA256);
    assert.equal(sha256(JSON.stringify(catalog.data)), HANDY_CATALOG_CANONICAL_SHA256);
    assert.deepEqual(CURATED_MODELS, catalog.data.models.filter(model => model.role === 'asr' && model.curated));
    assert.equal(CURATED_MODELS.length, 29);

    const refCommitPath = path.join(reference, 'COMMIT');
    const refCatalogPath = path.join(reference, 'src-tauri/src/catalog/catalog.json');
    const hasReference = existsSync(refCommitPath) && existsSync(refCatalogPath);
    if (requireReference && !hasReference) {
        const error = new Error(`Handy reference directory missing required files: ${reference}`);
        error.code = 'ENOENT';
        throw error;
    }
    if (hasReference) {
        const expectedRaw = readFileSync(refCatalogPath);
        const expected = JSON.parse(expectedRaw.toString('utf8'));
        assert.equal(readFileSync(refCommitPath, 'utf8').trim(), HANDY_COMMIT);
        assert.equal(sha256(expectedRaw), HANDY_CATALOG_SHA256);
        assert.deepEqual(catalog.data, expected);
    }
    return CURATED_MODELS.length;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    const args = process.argv.slice(2);
    if (args[0] !== '--check' || (args.length !== 1 && !(args.length === 3 && args[1] === '--ref'))) {
        console.error('Usage: node scripts/sync_handy_speech_catalog.mjs --check [--ref <handy-root>]');
        process.exitCode = 1;
    } else {
        try {
            const explicitRef = args.length === 3 ? args[2] : undefined;
            const count = checkCatalog(explicitRef ?? REFERENCE_DIR, { requireReference: explicitRef !== undefined });
            console.log(`Handy package matches the pinned catalog (${count} curated ASR models).`);
        } catch (error) {
            // Avoid printing the full catalog on a deep comparison error.
            console.error(`Handy catalog check failed (${error.code ?? error.name}).`);
            process.exitCode = 1;
        }
    }
}
