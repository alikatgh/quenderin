import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const patch = JSON.parse(await readFile(new URL('../patches/node-llama-cpp-3.19.1-prism-e8fd209.json', import.meta.url), 'utf8'));
const entry = patch.files.find((file) => file.path === 'dist/bindings/utils/cloneLlamaCppRepo.js');
const official = await readFile(new URL('./fixtures/node-llama-cpp-3.19.1/cloneLlamaCppRepo.js', import.meta.url), 'utf8');
const edit = entry.replacements[0];
assert.equal(official.split(edit.before).length, 2);
const patched = official.replace(edit.before, edit.after);
const start = patched.indexOf('export async function getClonedLlamaCppRepoReleaseInfo()');
const end = patched.indexOf('export async function isLlamaCppRepoCloned(', start);
const functionSource = patched.slice(start, end).replace('export async function ', 'async function ');

async function withPackage(callback) {
    const directory = await mkdtemp(path.join(os.tmpdir(), 'quenderin-prism-loader-test-'));
    const source = path.join(directory, 'llama.cpp');
    const info = path.join(directory, 'llama.cpp.info.json');
    const stamp = path.join(directory, 'quenderin-prism-node-runtime.json');
    const state = { cloned: false, locked: false };
    const context = vm.createContext({
        path,
        fs: {
            pathExists: async (candidate) => existsSync(candidate),
            readJson: async (candidate) => JSON.parse(await readFile(candidate, 'utf8')),
        },
        llamaCppDirectory: source,
        llamaCppDirectoryInfoFilePath: info,
        isLlamaCppRepoCloned: async () => state.cloned,
        isLockfileActive: async () => state.locked,
        getConsoleLogPrefix: () => '',
        console: { error() {} },
    });
    vm.runInContext(functionSource, context);
    const metadata = { tag: patch.runtimeRevision, llamaCppGithubRepo: 'PrismML-Eng/llama.cpp' };
    const provenance = {
        version: 1,
        repository: 'https://github.com/PrismML-Eng/llama.cpp.git',
        revision: patch.runtimeRevision,
        nodeLlamaCppVersion: patch.packageVersion,
    };
    try {
        await callback({
            source, info, stamp, state, metadata, provenance,
            getInfo: context.getClonedLlamaCppRepoReleaseInfo,
            prepareMetadata: async () => {
                await writeFile(info, JSON.stringify(metadata));
                await writeFile(stamp, JSON.stringify(provenance));
            },
        });
    } finally {
        // The test exclusively created this small, private directory above.
        await rm(directory, { recursive: true });
    }
}

test('unstamped packages cannot acquire Prism source metadata', async () => {
    await withPackage(async ({ info, metadata, getInfo }) => {
        await writeFile(info, JSON.stringify(metadata));
        assert.equal(await getInfo(), null);
    });
});

test('prepared packaged metadata locates the exact runtime without its source checkout', async () => {
    await withPackage(async ({ prepareMetadata, getInfo, metadata }) => {
        await prepareMetadata();
        assert.deepEqual(await getInfo(), metadata);
    });
});

test('changed stamp and source pins fail closed', async () => {
    await withPackage(async ({ prepareMetadata, getInfo, stamp, info, provenance, metadata }) => {
        for (const change of [
            { version: 2 },
            { repository: 'https://github.com/ggml-org/llama.cpp.git' },
            { revision: 'wrong' },
            { nodeLlamaCppVersion: '3.19.2' },
        ]) {
            await prepareMetadata();
            await writeFile(stamp, JSON.stringify({ ...provenance, ...change }));
            assert.equal(await getInfo(), null);
        }
        for (const change of [{ tag: 'wrong' }, { llamaCppGithubRepo: 'ggml-org/llama.cpp' }]) {
            await prepareMetadata();
            await writeFile(info, JSON.stringify({ ...metadata, ...change }));
            assert.equal(await getInfo(), null);
        }
    });
});

test('incomplete checkouts and active checkout locks are rejected', async () => {
    await withPackage(async ({ prepareMetadata, getInfo, source }) => {
        await prepareMetadata();
        await mkdir(source);
        assert.equal(await getInfo(), null);
    });
    await withPackage(async ({ prepareMetadata, getInfo, state }) => {
        await prepareMetadata();
        state.locked = true;
        assert.equal(await getInfo(), null);
    });
});

test('normal cloned standard runtimes retain their existing metadata behavior', async () => {
    await withPackage(async ({ info, state, getInfo }) => {
        state.cloned = true;
        const standard = { tag: 'b9000', llamaCppGithubRepo: 'ggml-org/llama.cpp' };
        await writeFile(info, JSON.stringify(standard));
        assert.deepEqual(await getInfo(), standard);
    });
});

test('malformed preparation stamps fail closed', async () => {
    await withPackage(async ({ prepareMetadata, getInfo, stamp }) => {
        await prepareMetadata();
        await writeFile(stamp, '{broken');
        assert.equal(await getInfo(), null);
    });
});
