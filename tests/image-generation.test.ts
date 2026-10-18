import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn, type SpawnOptions } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { PNG } from 'pngjs';
import { ImageGenerationService, IMAGE_MEMORY_REQUIRED_BYTES,
    type ImageModelCatalog, type DiffusionRuntimeLock } from '../src/services/imageGeneration.js';

const REVISION = 'f0aac524d3f29140e60ba78f3cfb16d6acea87db';
const LOCK: DiffusionRuntimeLock = { version: 1, abiVersion: 1, revision: REVISION,
    bounds: { maxDimension: 1024, maxSteps: 50, maxThreads: 8, maxImages: 1 } };
let directory: string;
let runtime: string;
let output: string;
let catalog: ImageModelCatalog;
let mode: string;
let calls: { file: string; args: string[]; options: SpawnOptions }[];
let signals: (NodeJS.Signals | number | undefined)[];

beforeEach(async () => {
    directory = await fs.promises.realpath(await fs.promises.mkdtemp(path.join(os.tmpdir(), 'quenderin-image-test-')));
    output = path.join(directory, 'new.png');
    runtime = path.join(directory, 'fixture-runtime.mjs');
    mode = 'success'; calls = []; signals = [];
    const files = [
        { role: 'diffusion' as const, filename: 'diffusion.safetensors', bytes: Buffer.from('diffusion fixture') },
        { role: 'text_encoder' as const, filename: 'encoder.gguf', bytes: Buffer.from('GGUF tiny fixture') },
        { role: 'vae' as const, filename: 'vae.safetensors', bytes: Buffer.from('vae fixture') },
        { role: 'tokenizer' as const, filename: 'tokenizer.json', bytes: Buffer.from('{"fixture":true}') },
    ];
    for (const file of files) await fs.promises.writeFile(path.join(directory, file.filename), file.bytes);
    catalog = { version: 1, status: 'experimental-source-integration-no-inference-validation', models: [{
        id: 'moss-image-base', label: 'MOSS fixture', modelKind: 2, license: 'Apache-2.0',
        licenseUrl: 'https://huggingface.co/OpenMOSS-Team/MOSS-Image-Base', requiresPublisherAccess: false,
        defaults: { width: 64, height: 64, steps: 50 },
        components: files.map(file => ({ role: file.role, localFilename: file.filename, bytes: file.bytes.length,
            sha256: crypto.createHash('sha256').update(file.bytes).digest('hex') })),
    }] };
    const pngModule = pathToFileURL(path.resolve('node_modules/pngjs/lib/png.js')).href;
    await fs.promises.writeFile(runtime, `import fs from 'node:fs';
import { PNG } from ${JSON.stringify(pngModule)};
const args = process.argv.slice(2); const mode = args.shift();
if (args.includes('--version')) {
    if (mode === 'bad-version') console.log(JSON.stringify({abiVersion: 0, revision: ${JSON.stringify(REVISION)}}));
    else console.log(JSON.stringify({abiVersion: 1, revision: ${JSON.stringify(REVISION)}}));
} else {
    const options = Object.fromEntries(Array.from({length: args.length / 2}, (_, i) => [args[i * 2], args[i * 2 + 1]]));
    if (mode === 'cancel') process.on('SIGINT', () => process.exit(0));
    if (mode === 'hang') process.on('SIGINT', () => {});
    process.stderr.write(JSON.stringify({step: 1, steps: 50}) + '\\n');
    if (mode === 'hang' || mode === 'cancel') setInterval(() => {}, 1000);
    else if (mode === 'flood') { process.stdout.write('x'.repeat(20000)); setInterval(() => {}, 1000); }
    else if (mode === 'progress-flood') { process.stderr.write('x'.repeat(70000)); setInterval(() => {}, 1000); }
    else if (mode === 'failure') process.exit(2);
    else {
        if (mode !== 'missing-output') {
            const image = new PNG({width: mode === 'wrong-size' ? 80 : Number(options['--width']), height: Number(options['--height'])});
            let encoded = PNG.sync.write(image);
            if (mode === 'duplicate-ihdr') {
                const second = PNG.sync.write(new PNG({width: 128, height: 128}));
                encoded = Buffer.concat([encoded.subarray(0, 33), second.subarray(8, 33), encoded.subarray(33)]);
            }
            if (mode === 'interlaced') encoded[28] = 1;
            if (mode === 'bad-png-crc') encoded[encoded.length - 1] ^= 1;
            fs.writeFileSync(options['--output'], encoded, {flag: 'wx'});
        }
        const response = Buffer.from(JSON.stringify({ok: true, path: options['--output'], width: Number(options['--width']), height: Number(options['--height'])}));
        if (mode === 'split-unicode') {
            const index = response.findIndex(byte => byte >= 128) + 1;
            process.stdout.write(response.subarray(0, index));
            setTimeout(() => process.stdout.write(response.subarray(index)), 10);
        } else process.stdout.write(response);
    }
}
`, { mode: 0o700 });
});

afterEach(async () => {
    vi.restoreAllMocks();
    // Every path is a fresh tiny fixture owned by this test, never user model data.
    await fs.promises.rm(directory, { recursive: true, force: true });
});

function service(overrides: Parameters<typeof makeService>[0] = {}): ImageGenerationService { return makeService(overrides); }
function makeService(overrides: { memory?: number; disk?: bigint; timeout?: number; grace?: number } = {}): ImageGenerationService {
    return new ImageGenerationService({ catalog, runtimeLock: LOCK, bundledRuntimePath: runtime,
        availableMemoryBytes: () => overrides.memory ?? IMAGE_MEMORY_REQUIRED_BYTES,
        freeDiskBytes: async () => overrides.disk ?? BigInt(1024 ** 3),
        timeoutMs: overrides.timeout, killGraceMs: overrides.grace ?? 40,
        spawnProcess: (file, args, options) => {
            calls.push({ file, args, options });
            const child = spawn(process.execPath, [runtime, mode, ...args], options);
            const kill = child.kill.bind(child);
            vi.spyOn(child, 'kill').mockImplementation(signal => { signals.push(signal); return kill(signal); });
            return child;
        },
    });
}

function request() { return { model: 'moss-image-base', directory, prompt: 'A quiet waterfall city.', output }; }

describe('complete prepared image components', () => {
    it('verifies every pinned size and digest without launching a runtime', async () => {
        const result = await service().verify('moss-image-base', directory);
        expect(result.components).toBe(4);
        expect(result.bytes).toBe(catalog.models[0].components.reduce((n, c) => n + c.bytes, 0));
        expect(calls).toHaveLength(0);
    });

    it('rejects wrong hashes, changed sizes and missing components', async () => {
        const filename = path.join(directory, 'diffusion.safetensors');
        const original = await fs.promises.readFile(filename);
        await fs.promises.writeFile(filename, Buffer.alloc(original.length));
        await expect(service().verify('moss-image-base', directory)).rejects.toThrow('SHA-256');
        await fs.promises.writeFile(filename, 'short');
        await expect(service().verify('moss-image-base', directory)).rejects.toThrow('size');
        await fs.promises.unlink(filename);
        await expect(service().verify('moss-image-base', directory)).rejects.toThrow();
        expect(calls).toHaveLength(0);
    });

    it('rejects symlink components and unsafe/incomplete manifests', async () => {
        const filename = path.join(directory, 'diffusion.safetensors');
        const preserved = path.join(directory, 'preserved.bin');
        await fs.promises.rename(filename, preserved);
        await fs.promises.symlink(preserved, filename);
        await expect(service().verify('moss-image-base', directory)).rejects.toThrow('regular file');
        expect((await fs.promises.readFile(preserved)).length).toBeGreaterThan(0);
        catalog.models[0].components[0].localFilename = '../outside.safetensors';
        expect(() => service()).toThrow('manifest');
        catalog.models[0].components.shift();
        expect(() => service()).toThrow('complete');
    });
});

describe('bounded local image generation', () => {
    it('probes the pinned ABI/revision and invokes argv directly before reporting an actual PNG', async () => {
        const prompt = 'Full scene caption; $(touch never) `no shell` "quoted"';
        const progress = vi.fn();
        const result = await service().generate({ ...request(), prompt, onProgress: progress });
        expect(result).toEqual({ path: output, width: 64, height: 64 });
        expect(calls).toHaveLength(2);
        expect(calls[0].args).toEqual(['--version']);
        expect(calls[1].options.shell).toBe(false);
        expect(calls[1].args[calls[1].args.indexOf('--prompt') + 1]).toBe(prompt);
        expect(calls[1].args).toContain('--tokenizer');
        expect(progress).toHaveBeenCalledWith({ step: 1, steps: 50 });
        expect((await fs.promises.readFile(output)).subarray(0, 8)).toEqual(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
    });

    it('blocks the complete pipeline below 24 GiB available memory or insufficient disk', async () => {
        await expect(service({ memory: IMAGE_MEMORY_REQUIRED_BYTES - 1 }).generate(request())).rejects.toThrow('24 GiB');
        await expect(service({ disk: BigInt(0) }).generate(request())).rejects.toThrow('disk');
        expect(calls).toHaveLength(0);
    });

    it('preserves existing files and dangling symlinks at the requested output', async () => {
        await fs.promises.writeFile(output, 'original');
        await expect(service().generate(request())).rejects.toThrow('already exists');
        expect(await fs.promises.readFile(output, 'utf8')).toBe('original');
        await fs.promises.unlink(output);
        await fs.promises.symlink(path.join(directory, 'absent'), output);
        await expect(service().generate(request())).rejects.toThrow('already exists');
        expect((await fs.promises.lstat(output)).isSymbolicLink()).toBe(true);
        expect(calls).toHaveLength(0);
    });

    it('rejects a mismatched runtime before generation', async () => {
        mode = 'bad-version';
        await expect(service().generate(request())).rejects.toThrow('ABI or source revision');
        expect(calls).toHaveLength(1);
        expect(fs.existsSync(output)).toBe(false);
    });

    it.each(['missing-output', 'wrong-size', 'bad-png-crc', 'failure'])('does not report success for %s', async value => {
        mode = value;
        await expect(service().generate(request())).rejects.toThrow();
    });

    it.each(['duplicate-ihdr', 'interlaced'])('rejects %s before the service pixel decoder runs', async value => {
        mode = value;
        const decode = vi.spyOn(PNG.sync, 'read');
        await expect(service().generate(request())).rejects.toThrow('structure');
        expect(decode).not.toHaveBeenCalled();
    });

    it('preserves UTF-8 output paths split between native stdout chunks', async () => {
        mode = 'split-unicode';
        output = path.join(directory, '光と水.png');
        await expect(service().generate(request())).resolves.toHaveProperty('path', output);
    });

    it.each(['flood', 'progress-flood'])('stops bounded output overflow (%s)', async value => {
        mode = value;
        await expect(service().generate(request())).rejects.toThrow(/bounded|limit/u);
        expect(signals).toContain('SIGINT');
    });

    it('cancels cooperatively with SIGINT and releases the per-process generation slot', async () => {
        mode = 'cancel';
        const controller = new AbortController();
        const instance = service();
        const promise = instance.generate({ ...request(), signal: controller.signal, onProgress: () => controller.abort() });
        await expect(instance.generate(request())).rejects.toThrow('already running');
        await expect(promise).rejects.toThrow('cancelled');
        expect(signals).toEqual(['SIGINT']);
        mode = 'success';
        await expect(instance.generate(request())).resolves.toHaveProperty('path', output);
    });

    it('escalates uncooperative cancellation to SIGKILL after the bounded grace', async () => {
        mode = 'hang';
        const controller = new AbortController();
        await expect(service().generate({ ...request(), signal: controller.signal,
            onProgress: () => controller.abort() })).rejects.toThrow('cancelled');
        expect(signals).toEqual(['SIGINT', 'SIGKILL']);
    });

    it('bounds total runtime and rejects already-cancelled operations without spawning', async () => {
        mode = 'hang';
        await expect(service({ timeout: 20 }).generate(request())).rejects.toThrow('time limit');
        const controller = new AbortController(); controller.abort();
        calls = [];
        await expect(service().generate({ ...request(), signal: controller.signal })).rejects.toThrow('cancelled');
        expect(calls).toHaveLength(0);
    });
});
