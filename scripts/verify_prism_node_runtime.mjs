#!/usr/bin/env node
// Executes the real native addon without downloading a model or building code.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const packageDir = path.resolve(process.argv[2] ?? path.join(root, 'node_modules/node-llama-cpp'));
const lock = JSON.parse(await readFile(path.join(root, 'shared/prism-runtime.json'), 'utf8'));
const { getLlama } = await import(pathToFileURL(path.join(packageDir, 'dist/index.js')).href);
const llama = await getLlama({
    gpu: false,
    build: 'never',
    usePrebuiltBinaries: false,
    skipDownload: true,
    progressLogs: false,
});
try {
    assert.equal(llama.buildType, 'localBuild');
    assert.deepEqual(llama.llamaCppRelease, {
        repo: 'PrismML-Eng/llama.cpp',
        release: lock.revision,
    });
    // These IDs and sizes come from the exact pinned ggml.h/ggml-common.h.
    // Calling the compiled exports establishes that the runtime really has the
    // packed ternary type table; a copied JSON provenance stamp cannot pass.
    for (const [name, type, bytes] of [['PQ2_0', 142, 34], ['PTQ1_0', 143, 28]]) {
        assert.equal(llama._bindings.getBlockSizeForGgmlType(type), 128, `${name} block size`);
        assert.equal(llama._bindings.getTypeSizeForGgmlType(type), bytes, `${name} packed size`);
    }
    console.log(JSON.stringify({
        buildType: llama.buildType,
        llamaCppRelease: llama.llamaCppRelease,
        nativeTernaryTypes: ['PQ2_0', 'PTQ1_0'],
    }));
} finally {
    await llama.dispose();
}
