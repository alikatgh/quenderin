#!/usr/bin/env node
/**
 * Regenerate shared/handy-speech-catalog.json from Handy's real catalog.
 *
 * Source of truth (read-only, never vendored into this repo):
 *   <ref>/src-tauri/src/catalog/catalog.json   Handy's catalog (schema 2)
 *   <ref>/pkg/package/catalog.json             @handy-computer/models@0.2.3 copy
 *   <ref>/pkg/package/package.json             package identity (version, license)
 *   <ref>/COMMIT                               Handy commit the snapshot pins
 *   <ref>/LICENSE                              Handy MIT copyright line
 *
 * The snapshot contains exactly the models with role="asr" AND curated=true.
 * No value is invented: ids, sizes, hashes, URLs, results, methodology and
 * benchmarks are copied from the reference. Only the download URL is composed
 * from the catalog's own repository/revision/filename rule:
 *   https://huggingface.co/{repository}/resolve/{revision}/{filename}
 *
 * Usage:
 *   node scripts/sync_handy_speech_catalog.mjs [--ref <handy-root>] [--out <json>]
 *   node scripts/sync_handy_speech_catalog.mjs --check
 *
 * --check exits 1 when the committed snapshot differs from a fresh generation,
 * so CI can prove the snapshot is in parity with the pinned reference.
 * It never downloads model weights and never touches the network.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');
const DEFAULT_REF = process.env.HANDY_REF || '/workspace/handy-ref';
const DEFAULT_OUT = path.join(REPO_ROOT, 'shared', 'handy-speech-catalog.json');
const EXPECTED_PACKAGE_VERSION = '0.2.3';
const EXPECTED_ASR_CURATED = 29;
const SNAPSHOT_SCHEMA = 1;

function readJson(file) {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function requireString(value, label) {
    if (typeof value !== 'string' || value.length === 0) {
        throw new Error(`${label} must be a non-empty string.`);
    }
    return value;
}

function requireNumber(value, label) {
    if (typeof value !== 'number' || !Number.isFinite(value)) {
        throw new Error(`${label} must be a finite number.`);
    }
    return value;
}

/** The catalog's own default-quant rule: `files[quant]` is the shipped artifact. */
function chosenFile(model, label) {
    const quant = requireString(model.quant, `${label}.quant`);
    const files = model.files;
    if (!files || typeof files !== 'object') {
        throw new Error(`${label}.files is missing.`);
    }
    const file = files[quant];
    if (!file) {
        throw new Error(`${label} has no file for its default quant ${quant}.`);
    }
    const filename = requireString(file.filename, `${label}.files.${quant}.filename`);
    const size = requireNumber(file.size, `${label}.files.${quant}.size`);
    const sha256 = requireString(file.sha256, `${label}.files.${quant}.sha256`);
    if (!/^[0-9a-f]{64}$/.test(sha256)) {
        throw new Error(`${label}.files.${quant}.sha256 is not a lowercase SHA-256.`);
    }
    const repository = requireString(model.repository, `${label}.repository`);
    const revision = requireString(model.revision, `${label}.revision`);
    return {
        quant,
        filename,
        size,
        sha256,
        url: `https://huggingface.co/${repository}/resolve/${revision}/${filename}`,
    };
}

function copyModel(model, label) {
    if (model.role !== 'asr' || model.curated !== true) {
        throw new Error(`${label} is not a curated ASR model.`);
    }
    const languages = Array.isArray(model.languages) ? model.languages : null;
    if (!languages || languages.length === 0) {
        throw new Error(`${label}.languages must be a non-empty array.`);
    }
    const capabilities = model.capabilities && typeof model.capabilities === 'object'
        ? {
            streaming: model.capabilities.streaming === true,
            translate: model.capabilities.translate === true,
            languageDetection: model.capabilities.languageDetection === true,
            timestamps: model.capabilities.timestamps === true,
        }
        : null;
    if (!capabilities) throw new Error(`${label}.capabilities is missing.`);
    return {
        id: requireString(model.id, `${label}.id`),
        name: requireString(model.name, `${label}.name`),
        description: typeof model.description === 'string' ? model.description : '',
        repository: requireString(model.repository, `${label}.repository`),
        revision: requireString(model.revision, `${label}.revision`),
        previousRevisions: Array.isArray(model.previousRevisions)
            ? model.previousRevisions.filter((revision) => typeof revision === 'string')
            : [],
        license: requireString(model.license, `${label}.license`),
        family: requireString(model.family, `${label}.family`),
        parameters: typeof model.parameters === 'string' ? model.parameters : null,
        languages,
        capabilities,
        quant: requireString(model.quant, `${label}.quant`),
        role: 'asr',
        curated: true,
        minEngine: requireString(model.minEngine, `${label}.minEngine`),
        file: chosenFile(model, label),
    };
}

/**
 * Build the snapshot object from a Handy reference checkout. Pure and
 * deterministic: the same reference bytes always produce the same JSON.
 */
export function buildSnapshot(refRoot = DEFAULT_REF) {
    const catalogPath = path.join(refRoot, 'src-tauri', 'src', 'catalog', 'catalog.json');
    const pkgCatalogPath = path.join(refRoot, 'pkg', 'package', 'catalog.json');
    const pkgManifestPath = path.join(refRoot, 'pkg', 'package', 'package.json');
    const commitPath = path.join(refRoot, 'COMMIT');
    const licensePath = path.join(refRoot, 'LICENSE');

    for (const file of [catalogPath, pkgCatalogPath, pkgManifestPath, commitPath, licensePath]) {
        if (!fs.existsSync(file)) {
            throw new Error(`Missing Handy reference file: ${file}`);
        }
    }

    const catalog = readJson(catalogPath);
    const pkgCatalog = readJson(pkgCatalogPath);
    const pkgManifest = readJson(pkgManifestPath);
    const commit = fs.readFileSync(commitPath, 'utf8').trim();

    if (catalog.schema !== 2) {
        throw new Error(`Unsupported Handy catalog schema ${String(catalog.schema)}; expected 2.`);
    }
    if (pkgManifest.name !== '@handy-computer/models' || pkgManifest.version !== EXPECTED_PACKAGE_VERSION) {
        throw new Error(
            `Expected @handy-computer/models@${EXPECTED_PACKAGE_VERSION}, got ${String(pkgManifest.name)}@${String(pkgManifest.version)}.`,
        );
    }
    if (JSON.stringify(catalog.models) !== JSON.stringify(pkgCatalog.models)) {
        throw new Error('Handy src-tauri catalog and the @handy-computer/models copy disagree; refusing to pick one.');
    }
    if (!/^[0-9a-f]{40}$/.test(commit)) {
        throw new Error('Handy COMMIT is not a full 40-character git commit.');
    }

    const licenseText = fs.readFileSync(licensePath, 'utf8');
    const copyrightLine = licenseText
        .split(/\r?\n/)
        .map((line) => line.trim())
        .find((line) => line.startsWith('Copyright (c) '));
    if (!copyrightLine) throw new Error('Handy LICENSE has no copyright line.');

    const models = catalog.models
        .filter((model) => model.role === 'asr' && model.curated === true)
        .map((model) => copyModel(model, `models[${String(model.id)}]`));

    if (models.length !== EXPECTED_ASR_CURATED) {
        throw new Error(
            `Expected ${EXPECTED_ASR_CURATED} curated ASR models, found ${models.length}. ` +
            'The snapshot is pinned to the reference; investigate the catalog instead of changing the count.',
        );
    }
    const ids = new Set(models.map((model) => model.id));
    if (ids.size !== models.length) throw new Error('Duplicate model ids in catalog.');

    const results = {};
    for (const model of models) {
        const result = catalog.results?.[model.id];
        if (!result || typeof result.accuracy !== 'object' || typeof result.performance !== 'object') {
            throw new Error(`Missing benchmark results for curated ASR model ${model.id}.`);
        }
        results[model.id] = result;
    }

    return {
        schema: SNAPSHOT_SCHEMA,
        source: {
            handy: {
                name: 'Handy',
                repository: 'https://github.com/cjpais/Handy',
                commit,
                catalogPath: 'src-tauri/src/catalog/catalog.json',
                license: 'MIT',
                copyright: copyrightLine,
            },
            package: {
                name: '@handy-computer/models',
                version: pkgManifest.version,
                repository: 'https://github.com/handy-computer/models',
                catalogPath: 'pkg/package/catalog.json',
                license: 'MIT',
            },
            generator: 'scripts/sync_handy_speech_catalog.mjs',
        },
        transcribeCpp: requireString(catalog.transcribeCpp, 'transcribeCpp'),
        languageDetector: requireString(catalog.languageDetector, 'languageDetector'),
        methodology: catalog.methodology,
        benchmarks: catalog.benchmarks,
        models,
        results,
    };
}

export function serialize(snapshot) {
    return JSON.stringify(snapshot, null, 2) + '\n';
}

function parseArgs(argv) {
    const options = { ref: DEFAULT_REF, out: DEFAULT_OUT, check: false };
    for (let index = 0; index < argv.length; index += 1) {
        const arg = argv[index];
        if (arg === '--check') options.check = true;
        else if (arg === '--ref') options.ref = path.resolve(argv[++index] ?? '');
        else if (arg === '--out') options.out = path.resolve(argv[++index] ?? '');
        else if (arg === '--help' || arg === '-h') options.help = true;
        else throw new Error(`Unknown argument: ${arg}`);
    }
    return options;
}

function main(argv) {
    const options = parseArgs(argv);
    if (options.help) {
        process.stdout.write(
            'Usage: node scripts/sync_handy_speech_catalog.mjs [--ref <handy-root>] [--out <json>] [--check]\n',
        );
        return 0;
    }
    const generated = serialize(buildSnapshot(options.ref));
    if (options.check) {
        if (!fs.existsSync(options.out)) {
            process.stderr.write(`Missing snapshot: ${options.out}\n`);
            return 1;
        }
        const current = fs.readFileSync(options.out, 'utf8');
        if (current !== generated) {
            process.stderr.write(
                `Snapshot is out of date with ${options.ref}.\n` +
                'Run: node scripts/sync_handy_speech_catalog.mjs\n',
            );
            return 1;
        }
        process.stdout.write(`Snapshot matches ${options.ref} (${EXPECTED_ASR_CURATED} curated ASR models).\n`);
        return 0;
    }
    fs.mkdirSync(path.dirname(options.out), { recursive: true });
    fs.writeFileSync(options.out, generated, 'utf8');
    process.stdout.write(`Wrote ${options.out} (${EXPECTED_ASR_CURATED} curated ASR models).\n`);
    return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
    try {
        process.exitCode = main(process.argv.slice(2));
    } catch (error) {
        process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
        process.exitCode = 1;
    }
}
