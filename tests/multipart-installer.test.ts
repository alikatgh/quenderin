import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import * as manifests from '../src/services/multipartModels.js';
import { installMultipartModel, verifyMultipartModel, installArtifactSet, verifyArtifactSet } from '../src/services/multipartInstaller.js';

let directory: string;
const bytes = [1, 2, 3, 4].map(index => Buffer.from(`GGUFsynthetic-${index}`));
const parts = bytes.map((data, i) => ({ filename: `fixture-${i + 1}.gguf`, url: `https://huggingface.co/fixture/synthetic/resolve/${"a".repeat(40)}/${i + 1}`, downloadBytes: data.length,
    sha256: crypto.createHash('sha256').update(data).digest('hex') }));
const descriptor = { filename: parts[0].filename };
beforeEach(() => {
    directory = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'beam-installer-fixture-')));
    vi.spyOn(manifests, 'pinnedMultipartParts').mockReturnValue(parts);
    vi.spyOn(fs.promises, 'statfs').mockResolvedValue({ bavail: 2n * 1024n ** 3n, bsize: 1n } as fs.BigIntStatsFs);
});
afterEach(() => { vi.restoreAllMocks(); fs.rmSync(directory, { recursive: true }); });

describe('actual multipart install/load boundary, synthetic bytes only', () => {
    it('rejects insufficient whole-set disk headroom before fetching any shard', async () => {
        vi.mocked(fs.promises.statfs).mockResolvedValue({ bavail: 512n * 1024n ** 2n, bsize: 1n } as fs.BigIntStatsFs);
        const request = vi.fn();
        await expect(installArtifactSet(parts, directory, () => {}, request)).rejects.toThrow('Insufficient disk space');
        expect(request).not.toHaveBeenCalled();
    });
    it.each([true, false])('credits valid existing partials under tight free space (Range honored=%s)', async honorRange => {
        for (let index = 0; index < parts.length - 1; index++) fs.writeFileSync(path.join(directory, parts[index].filename), bytes[index]);
        const part = parts.at(-1)!, content = bytes.at(-1)!, offset = content.length - 3;
        fs.writeFileSync(path.join(directory, part.filename + '.download.part'), content.subarray(0, offset));
        fs.writeFileSync(path.join(directory, part.filename + '.download.json'), JSON.stringify(part));
        vi.spyOn(fs.promises, 'statfs').mockResolvedValue({ bavail: BigInt(512 * 1024 ** 2 + 3), bsize: 1n } as fs.BigIntStatsFs);
        const request = vi.fn(async (_url: unknown, options: any) => {
            expect(options.headers.Range).toBe(`bytes=${offset}-`);
            return new Response(honorRange ? content.subarray(offset) : content, { status: honorRange ? 206 : 200,
                headers: honorRange ? { 'content-range': `bytes ${offset}-${content.length - 1}/${content.length}` } : {} });
        }) as typeof fetch;
        await installArtifactSet(parts, directory, () => {}, request);
        expect(fs.readFileSync(path.join(directory, part.filename))).toEqual(content);
        expect(request).toHaveBeenCalledTimes(1);
    });
    it('requires every shard, resumes interrupted transfer and publishes completion only after hashes', async () => {
        let interrupted = false;
        const request = vi.fn(async (url: any, options: any) => {
            const i = Number(String(url).split('/').pop()) - 1;
            const range = options.headers.Range;
            if (i === 1 && !interrupted) {
                interrupted = true;
                return new Response(new ReadableStream({ start(controller) { controller.enqueue(bytes[i].subarray(0, 6)); }, pull(controller) { controller.error(new Error('interrupted')); } }));
            }
            const start = range ? Number(range.match(/\d+/)[0]) : 0;
            return new Response(bytes[i].subarray(start), { status: range ? 206 : 200,
                headers: range ? { 'content-range': `bytes ${start}-${bytes[i].length - 1}/${bytes[i].length}` } : {} });
        }) as typeof fetch;
        const progress = vi.fn();
        await expect(installMultipartModel(descriptor, directory, progress, request)).rejects.toThrow('interrupted');
        expect(fs.existsSync(path.join(directory, parts[0].filename))).toBe(true);
        await expect(verifyMultipartModel(descriptor, path.join(directory, parts[0].filename))).rejects.toThrow();
        expect(progress.mock.calls.some(([value]) => value === 1)).toBe(false);
        await installMultipartModel(descriptor, directory, progress, request);
        await verifyMultipartModel(descriptor, path.join(directory, parts[0].filename));
        expect(progress.mock.calls.at(-1)?.[0]).toBe(1);
        expect(request.mock.calls.some(([, options]: any) => options.headers.Range === 'bytes=6-')).toBe(true);
    });
    it('threads caller cancellation into generic artifact transfers and verification', async () => {
        const controller = new AbortController();
        const request = vi.fn(async (_url: any, options: any) => {
            expect(options.signal).toBeInstanceOf(AbortSignal);
            controller.abort(new Error('fixture cancelled'));
            expect(options.signal.aborted).toBe(true);
            options.signal.throwIfAborted();
            return new Response(bytes[0]);
        }) as typeof fetch;
        await expect(installArtifactSet(parts, directory, () => {}, request, controller.signal)).rejects.toThrow('fixture cancelled');
        expect(request).toHaveBeenCalledTimes(1);
        await expect(verifyArtifactSet(parts, directory, controller.signal)).rejects.toThrow('fixture cancelled');
        expect(fs.existsSync(path.join(directory, parts[0].filename))).toBe(false);
    });
    it('preserves invalid originals and foreign partials without downloading or overwriting', async () => {
        const original = path.join(directory, parts[0].filename);
        fs.writeFileSync(original, 'user original');
        const request = vi.fn();
        await expect(installMultipartModel(descriptor, directory, () => {}, request)).rejects.toThrow();
        expect(fs.readFileSync(original, 'utf8')).toBe('user original');
        expect(request).not.toHaveBeenCalled();
    });
    it('refuses to write a recognized partial that aliases another original by hardlink', async () => {
        const original = path.join(directory, 'original');
        fs.writeFileSync(original, 'GGUF');
        const staging = path.join(directory, parts[0].filename + '.download.part');
        fs.linkSync(original, staging);
        fs.writeFileSync(path.join(directory, parts[0].filename + '.download.json'), JSON.stringify(parts[0]));
        const request = vi.fn(async () => new Response(bytes[0])) as typeof fetch;
        await expect(installArtifactSet(parts, directory, () => {}, request)).rejects.toThrow('exclusive ordinary file');
        expect(fs.readFileSync(original, 'utf8')).toBe('GGUF');
    });
    it('rejects first-shard-only load even when the first shard hash is correct', async () => {
        fs.writeFileSync(path.join(directory, parts[0].filename), bytes[0]);
        await expect(verifyMultipartModel(descriptor, path.join(directory, parts[0].filename))).rejects.toThrow();
    });
});
