#!/usr/bin/env node
// Run the existing full Bonsai model through the actual packaged desktop addon.
// This script never downloads a model or builds a runtime.
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const CHILD_MODE = '--packaged-generation';
const HARD_TIMEOUT_MS = 1_200_000;
const ABORT_TIMEOUT_MS = 1_140_000;

async function generate(resources, modelPath) {
    const expected = JSON.parse(await readFile(new URL('../shared/prism-runtime.json', import.meta.url), 'utf8'));
    const packaged = JSON.parse(await readFile(path.join(resources, 'app.asar/shared/prism-runtime.json'), 'utf8'));
    assert.deepEqual(packaged, expected, 'Packaged Prism/model pins differ from this verification revision');
    const modelFile = await stat(modelPath);
    assert.ok(modelFile.isFile(), 'Pass an existing full Bonsai GGUF model file');
    assert.equal(modelFile.size, expected.downloadBytes, 'Model size differs from the pinned full artifact');

    const { getLlama, LlamaChatSession } = await import(pathToFileURL(
        path.join(resources, 'app.asar/node_modules/node-llama-cpp/dist/index.js'),
    ).href);
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(new Error('Packaged generation deadline exceeded')), ABORT_TIMEOUT_MS);
    deadline.unref();
    let llama;
    let model;
    let context;
    let session;
    let failure;
    try {
        llama = await getLlama({
            gpu: false,
            build: 'never',
            usePrebuiltBinaries: false,
            skipDownload: true,
            progressLogs: false,
            maxThreads: 4,
        });
        assert.equal(llama.buildType, 'localBuild');
        assert.deepEqual(llama.llamaCppRelease, {
            repo: 'PrismML-Eng/llama.cpp',
            release: expected.revision,
        });
        for (const [name, type, bytes] of [['PQ2_0', 142, 34], ['PTQ1_0', 143, 28]]) {
            assert.equal(llama._bindings.getBlockSizeForGgmlType(type), 128, `${name} block size`);
            assert.equal(llama._bindings.getTypeSizeForGgmlType(type), bytes, `${name} packed size`);
        }
        console.log('Loading the full pinned Bonsai model through the packaged CPU addon…');
        model = await llama.loadModel({
            modelPath,
            gpuLayers: 0,
            useMmap: true,
            useMlock: false,
            useDirectIo: false,
            loadSignal: controller.signal,
        });
        context = await model.createContext({
            contextSize: 512,
            batchSize: 64,
            threads: 4,
            sequences: 1,
            flashAttention: false,
            failedCreationRemedy: false,
            createSignal: controller.signal,
        });
        assert.equal(context.contextSize, 512, 'The bounded context size changed');
        session = new LlamaChatSession({
            contextSequence: context.getSequence(),
            autoDisposeSequence: true,
        });
        // This is the app's no-thinking path. v3.19.1 supports thoughtTokens:0
        // directly; the normal model-selected chat wrapper closes that segment.
        const response = await session.prompt('Reply with the single word hello.', {
            maxTokens: 32,
            temperature: 0,
            budgets: { thoughtTokens: 0 },
            signal: controller.signal,
            stopOnAbortSignal: false,
        });
        assert.match(response.trim(), /^hello[.!]?$/i, 'Packaged model did not produce the requested hello answer');
        console.log(JSON.stringify({
            check: 'packaged-desktop-full-model-generation',
            modelId: expected.modelId,
            modelBytes: modelFile.size,
            buildType: llama.buildType,
            llamaCppRelease: llama.llamaCppRelease,
            nativeTernaryTypes: ['PQ2_0', 'PTQ1_0'],
            contextSize: context.contextSize,
            batchSize: 64,
            maxThreads: 4,
            maxTokens: 32,
            thoughtTokens: 0,
            chatWrapper: session.chatWrapper.wrapperName,
            response,
        }));
    } catch (error) {
        failure = error;
        throw error;
    } finally {
        clearTimeout(deadline);
        const cleanupErrors = [];
        for (const [name, resource] of [['session', session], ['context', context], ['model', model], ['llama', llama]]) {
            if (resource == null) continue;
            try {
                await resource.dispose();
            } catch (error) {
                cleanupErrors.push(error);
                console.error(`Failed to dispose ${name}:`, error);
            }
        }
        if (cleanupErrors.length > 0 && failure == null) {
            throw new AggregateError(cleanupErrors, 'Packaged model cleanup failed');
        }
    }
}

if (process.argv[2] === CHILD_MODE) {
    assert.equal(process.env.ELECTRON_RUN_AS_NODE, '1', 'Generation must run through the packaged Electron executable');
    assert.ok(process.versions.electron, 'Generation requires the actual packaged Electron runtime');
    assert.ok(process.argv[3] && process.argv[4], 'Missing packaged resources directory or model path');
    await generate(path.resolve(process.argv[3]), path.resolve(process.argv[4]));
} else {
    assert.ok(process.argv[2] && process.argv[3], 'Usage: node scripts/verify_prism_desktop_generation.mjs <packaged-resources-dir> <existing-full-model-path>');
    const resources = path.resolve(process.argv[2]);
    const modelPath = path.resolve(process.argv[3]);
    assert.ok(existsSync(path.join(resources, 'app.asar')), 'Packaged ASAR is missing');
    assert.ok(existsSync(path.join(resources, 'app.asar.unpacked/node_modules/node-llama-cpp/llama/localBuilds')),
        'Packaged local addon is missing');
    assert.ok((await stat(modelPath)).isFile(), 'Pass an existing full Bonsai GGUF model file');
    const names = process.platform === 'win32' ? ['Quenderin.exe'] : ['quenderin', 'quenderin-poc'];
    const executables = names.map(name => path.join(resources, '..', name)).filter(existsSync);
    assert.equal(executables.length, 1, 'Expected one packaged Quenderin executable');
    const result = spawnSync(executables[0], [fileURLToPath(import.meta.url), CHILD_MODE, resources, modelPath], {
        env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
        stdio: 'inherit',
        timeout: HARD_TIMEOUT_MS,
        killSignal: 'SIGKILL',
    });
    if (result.error) throw result.error;
    assert.equal(result.status, 0, `Packaged full-model generation failed (${result.signal ?? result.status})`);
}
