// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Cases adapted from Handy src-tauri/src/managers/model/download/tests.rs
// at 05efc5fc180197dc0fa9d568dd9812904b723b8b. See THIRD_PARTY_NOTICES.md.
import { catalog, modelFile } from '@handy-computer/models';
import { spawn } from 'node:child_process';
import { lstat, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { installedModelPath, modelDownloadUrl } from '../src/services/speech/catalog.js';
import {
    assertAllowedSpeechArtifactUrl,
    createSpeechArtifactFetch,
    speechDownloadFs,
    SpeechDownloadManager,
    type RawSpeechFetch,
    type SpeechDownloadFetch,
    type SpeechDownloadManagerOptions,
} from '../src/services/speech/downloadManager.js';
import type { SpeechDownloadSnapshot } from '../src/services/speech/types.js';
import { fixtureBytes, fixtureModel, httpFixture, speechFsFixture } from './helpers/speechFixtures.js';

const model = fixtureModel();
const second = fixtureModel({
    id: 'second-fixture',
    files: { [model.quant]: { ...modelFile(model), filename: 'second.gguf' } },
});
const final = installedModelPath('/fixture/speech', model);
const part = final + '.part';

describe('resumable Handy downloads', () => {
    const managers: SpeechDownloadManager[] = [];
    function setup(options: Partial<SpeechDownloadManagerOptions> = {}) {
        const disk = speechFsFixture();
        const fetch = vi.fn<SpeechDownloadFetch>();
        const events: SpeechDownloadSnapshot[] = [];
        const manager = new SpeechDownloadManager({
            catalog: { ...catalog, curatedModels: [model, second] },
            modelsDir: '/fixture/speech', pinnedEngineVersion: '0.4.1', fetchImpl: fetch, fs: disk.fs,
            sleep: async () => {}, onProgress: snapshot => events.push(snapshot), ...options,
        });
        managers.push(manager);
        return { ...disk, fetch, events, manager };
    }
    async function completes(manager: SpeechDownloadManager, phase: 'installed' | 'error') {
        return vi.waitFor(() => {
            const snapshot = manager.snapshot(model.id)!;
            expect(snapshot.phase).toBe(phase);
            return snapshot;
        });
    }
    afterEach(async () => { await Promise.all(managers.splice(0).map(manager => manager.shutdown())); });

    it('streams .part, throttles progress, then verifies and renames', async () => {
        let now = 0;
        const { manager, fetch, events, files } = setup({ now: () => now });
        fetch.mockResolvedValue({
            ...httpFixture(200, null),
            body: (async function* () {
                now += 1000;
                yield fixtureBytes.subarray(0, 4);
                expect(files.get(part)?.bytes).toEqual(fixtureBytes.subarray(0, 4));
                expect(files.has(final)).toBe(false);
                now += 1000;
                yield fixtureBytes.subarray(4);
                expect(files.has(final)).toBe(false);
            })(),
        });
        expect((await manager.start(model.id)).phase).toBe('queued');
        await completes(manager, 'installed');
        expect(events.some(e => e.downloadedBytes === 4 && e.percent > 0 && e.percent < 100)).toBe(true);
        expect(events.some(e => e.bytesPerSecond != null && e.bytesPerSecond > 0)).toBe(true);
        expect(events.map(e => e.phase)).toContain('verifying');
        expect(files.has(part)).toBe(false);
        expect(files.get(final)?.bytes).toEqual(fixtureBytes);
        expect(fetch.mock.calls[0][0]).toBe(modelDownloadUrl(model));
    });

    it.each([206, 200, 416])('safely handles a ranged response with HTTP %s', async status => {
        const { manager, fetch, put, files } = setup();
        put(part, fixtureBytes.subarray(0, 4));
        expect((await manager.status(model.id))?.phase).toBe('paused');
        if (status === 206) {
            fetch.mockResolvedValueOnce(httpFixture(206, fixtureBytes.subarray(4), {
                'content-range': `bytes 4-${fixtureBytes.length - 1}/${fixtureBytes.length}`,
                'content-length': String(fixtureBytes.length - 4),
            }));
        } else if (status === 200) {
            fetch.mockResolvedValueOnce(httpFixture(200, fixtureBytes));
        } else {
            fetch.mockResolvedValueOnce(httpFixture(416, null)).mockResolvedValueOnce(httpFixture(200, fixtureBytes));
        }
        await manager.resume(model.id);
        await completes(manager, 'installed');
        expect(fetch.mock.calls[0][1].headers?.Range).toBe('bytes=4-');
        if (status === 416) expect(fetch.mock.calls[1][1].headers?.Range).toBeUndefined();
        expect(files.get(final)?.bytes).toEqual(fixtureBytes);
    });

    it('discards an incorrect Content-Range and exposes HTTP 416', async () => {
        const { manager, fetch, put, files } = setup();
        put(part, fixtureBytes.subarray(0, 4));
        fetch.mockResolvedValue(httpFixture(206, fixtureBytes.subarray(5), { 'content-range': 'bytes 5-20/21' }));
        await manager.start(model.id);
        const { error } = await completes(manager, 'error');
        expect(error).toMatchObject({ kind: 'http-416', status: 416 });
        expect(files.size).toBe(0);
    });

    it('clears a stale part and reports a repeated HTTP 416', async () => {
        const { manager, fetch, put, files } = setup();
        put(part, fixtureBytes.subarray(0, 4));
        fetch.mockResolvedValue(httpFixture(416, null));
        await manager.start(model.id);
        expect((await completes(manager, 'error')).error).toMatchObject({ kind: 'http-416', status: 416 });
        expect(fetch).toHaveBeenCalledTimes(2);
        expect(files.has(part)).toBe(false);
    });

    it('verifies a full-size partial without requesting beyond EOF', async () => {
        const { manager, fetch, put, files } = setup();
        put(part, fixtureBytes);
        await manager.start(model.id);
        await completes(manager, 'installed');
        expect(fetch).not.toHaveBeenCalled();
        expect(files.get(final)?.bytes).toEqual(fixtureBytes);
    });

    it('clears an oversized partial before connecting', async () => {
        const { manager, fetch, put, files } = setup();
        put(part, Buffer.alloc(fixtureBytes.length + 1));
        fetch.mockImplementation(async (_url, init) => {
            expect(init.headers?.Range).toBeUndefined();
            expect(files.has(part)).toBe(false);
            return httpFixture(200, fixtureBytes);
        });
        await manager.start(model.id);
        await completes(manager, 'installed');
    });

    it('rejects inconsistent advertised length before writing', async () => {
        const { manager, fetch, fs, put, files } = setup();
        put(part, fixtureBytes.subarray(0, 4));
        const open = vi.spyOn(fs, 'open');
        fetch.mockResolvedValue(httpFixture(206, fixtureBytes.subarray(4), {
            'content-range': 'bytes 4-20/21', 'content-length': '100',
        }));
        await manager.start(model.id);
        expect((await completes(manager, 'error')).error?.kind).toBe('http-size');
        expect(open).not.toHaveBeenCalled();
        expect(files.get(part)?.bytes.length).toBe(4);
    });

    it.each([
        ['short body', fixtureBytes.subarray(0, 2)],
        ['oversized body', Buffer.alloc(fixtureBytes.length + 1)],
        ['incorrect hash', Buffer.alloc(fixtureBytes.length)],
    ])('deletes an invalid partial after %s', async (_, body) => {
        const { manager, fetch, files } = setup();
        fetch.mockResolvedValue(httpFixture(200, body));
        await manager.start(model.id);
        expect((await completes(manager, 'error')).error?.kind).toBe('checksum-mismatch');
        expect(files.size).toBe(0);
        expect(fetch).toHaveBeenCalledTimes(1);
    });

    it('aborts a stalled body on pause; resumes, then cancels and removes the partial', async () => {
        const { manager, fetch, files } = setup();
        const stalled = (body: Buffer, status = 200) => ({
            ...httpFixture(status, null, { 'content-range': 'bytes 4-20/21' }),
            body: {
                async *[Symbol.asyncIterator]() {
                    yield body;
                    await new Promise<never>(() => {});
                },
            },
        });
        fetch.mockResolvedValueOnce(stalled(fixtureBytes.subarray(0, 4))).mockResolvedValueOnce(stalled(fixtureBytes.subarray(4, 6), 206));
        await manager.start(model.id);
        await vi.waitFor(() => expect(files.get(part)?.bytes.length).toBe(4));
        expect(await manager.pause(model.id)).toMatchObject({ phase: 'paused', downloadedBytes: 4 });
        expect(fetch.mock.calls[0][1].signal?.aborted).toBe(true);
        await manager.resume(model.id);
        await vi.waitFor(() => expect(files.get(part)?.bytes.length).toBe(6));
        expect((await manager.cancel(model.id)).phase).toBe('idle');
        expect(files.has(part)).toBe(false);
    });

    it('cancels while awaiting headers and starts the next queued model', async () => {
        const { manager, fetch } = setup();
        fetch.mockImplementationOnce(() => new Promise(() => {})).mockResolvedValueOnce(httpFixture(200, fixtureBytes));
        await manager.start(model.id);
        await manager.start(second.id);
        expect(manager.snapshot(second.id)?.phase).toBe('queued');
        await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
        await manager.cancel(model.id);
        expect(fetch.mock.calls[0][1].signal?.aborted).toBe(true);
        await vi.waitFor(() => expect(manager.snapshot(second.id)?.phase).toBe('installed'));
    });

    it('applies bounded exponential backoff to transient failures', async () => {
        const sleep = vi.fn(async () => {});
        const { manager, fetch } = setup({ sleep, random: () => 0.5, retry: { maxAttempts: 3, baseDelayMs: 50, maxDelayMs: 90 } });
        fetch.mockRejectedValueOnce(new Error('interrupted')).mockResolvedValue(httpFixture(503, null));
        await manager.start(model.id);
        expect((await completes(manager, 'error')).error).toMatchObject({ kind: 'network', status: 503 });
        expect(sleep.mock.calls.map(call => call[0])).toEqual([50, 90]);
        expect(fetch).toHaveBeenCalledTimes(3);
        fetch.mockResolvedValue(httpFixture(200, fixtureBytes));
        await manager.retry(model.id);
        await completes(manager, 'installed');
    });

    it('times out an unresponsive header request', async () => {
        const { manager, fetch } = setup({ networkIdleMs: 5, retry: { maxAttempts: 1, baseDelayMs: 1, maxDelayMs: 5 } });
        fetch.mockImplementation(() => new Promise(() => {}));
        await manager.start(model.id);
        expect((await completes(manager, 'error')).error?.kind).toBe('network');
    });

    it('surfaces ENOSPC while writing without finalizing', async () => {
        const { manager, fetch, files, fs } = setup();
        vi.spyOn(fs, 'open').mockResolvedValue({
            write: async () => { throw Object.assign(new Error('full'), { code: 'ENOSPC' }); },
            close: async () => {},
        });
        fetch.mockResolvedValue(httpFixture(200, fixtureBytes));
        await manager.start(model.id);
        expect((await completes(manager, 'error')).error?.kind).toBe('disk-full');
        expect(files.has(final)).toBe(false);
        expect(fetch).toHaveBeenCalledTimes(1);
    });

    it('reports a pinned artifact 404 without retrying', async () => {
        const { manager, fetch, files } = setup();
        fetch.mockResolvedValue(httpFixture(404, null));
        await manager.start(model.id);
        expect((await completes(manager, 'error')).error).toMatchObject({ kind: 'http-404', status: 404 });
        expect(fetch).toHaveBeenCalledTimes(1);
        expect(files.size).toBe(0);
    });

    it('gates the installed runtime before starting a download', async () => {
        const { manager, fetch } = setup({ pinnedEngineVersion: '0.0.1' });
        await expect(manager.start(model.id)).rejects.toMatchObject({ code: 'unsupported-engine', status: 409 });
        expect(fetch).not.toHaveBeenCalled();
    });

    it('verifies an existing file offline, rejects a new start and supports removal', async () => {
        const { manager, fetch, put, files } = setup();
        put(final, fixtureBytes);
        expect((await manager.verifyInstalled(model.id)).phase).toBe('installed');
        await expect(manager.start(model.id)).rejects.toMatchObject({ code: 'already-installed' });
        expect((await manager.remove(model.id)).phase).toBe('idle');
        expect(files.has(final)).toBe(false);
        expect(fetch).not.toHaveBeenCalled();
    });

    it('keeps a corrupted destination file intact on read-only verifyInstalled and replaces it on start', async () => {
        const { manager, fetch, put, files } = setup();
        put(final, Buffer.from('corrupt-bytes'));
        const checked = await manager.verifyInstalled(model.id);
        expect(checked.phase).toBe('idle');
        expect(files.has(final)).toBe(true);

        fetch.mockResolvedValue(httpFixture(200, fixtureBytes));
        await manager.start(model.id);
        await completes(manager, 'installed');
        expect(files.get(final)?.bytes).toEqual(fixtureBytes);
    });

    it('fails closed if the promoted destination file identity does not match the verified partial', async () => {
        const { manager, fetch, fs, files, put } = setup();
        fetch.mockResolvedValue(httpFixture(200, fixtureBytes));
        vi.spyOn(fs, 'rename').mockImplementation(async (from, to) => {
            files.delete(from);
            // Simulate an out-of-band file with a different inode appearing at destination.
            put(to, fixtureBytes);
        });
        await manager.start(model.id);
        expect((await completes(manager, 'error')).error?.kind).toBe('checksum-mismatch');
    });

    it('prevents two managers sharing a directory from corrupting or removing the same partial', async () => {
        const sharedDir = await mkdtemp(path.join(os.tmpdir(), 'quenderin-speech-lock-'));
        let releaseStream!: () => void;
        const gate = new Promise<void>(resolve => { releaseStream = resolve; });
        const fetchA = vi.fn<SpeechDownloadFetch>().mockResolvedValue({
            ...httpFixture(200, null),
            body: (async function* () {
                yield fixtureBytes.subarray(0, 5);
                await gate;
                yield fixtureBytes.subarray(5);
            })(),
        });
        const fetchB = vi.fn<SpeechDownloadFetch>().mockResolvedValue(httpFixture(200, fixtureBytes));
        const managerA = new SpeechDownloadManager({
            catalog: { ...catalog, curatedModels: [model] },
            modelsDir: sharedDir, pinnedEngineVersion: '0.4.1', fetchImpl: fetchA, fs: speechDownloadFs,
            sleep: async () => {},
        });
        const managerB = new SpeechDownloadManager({
            catalog: { ...catalog, curatedModels: [model] },
            modelsDir: sharedDir, pinnedEngineVersion: '0.4.1', fetchImpl: fetchB, fs: speechDownloadFs,
            sleep: async () => {},
        });
        managers.push(managerA, managerB);
        try {
            const destPath = installedModelPath(sharedDir, model);
            const partPath = destPath + '.part';
            await managerA.start(model.id);
            await vi.waitFor(async () => {
                expect(await readFile(partPath)).toEqual(fixtureBytes.subarray(0, 5));
            });

            // A second manager cannot cancel, remove, or start writing the locked artifact.
            await expect(managerB.cancel(model.id)).rejects.toMatchObject({ code: 'download-busy', status: 409 });
            await expect(managerB.remove(model.id)).rejects.toMatchObject({ code: 'download-busy', status: 409 });
            await managerB.start(model.id);
            await vi.waitFor(() => expect(managerB.snapshot(model.id)?.phase).toBe('error'));
            expect(fetchB).not.toHaveBeenCalled();
            expect(await readFile(partPath)).toEqual(fixtureBytes.subarray(0, 5));

            // Manager A finishes cleanly and releases the lock.
            releaseStream();
            await completes(managerA, 'installed');
            expect(await readFile(destPath)).toEqual(fixtureBytes);

            // After lock release, Manager B sees the verified installation and can remove it.
            expect((await managerB.verifyInstalled(model.id)).phase).toBe('installed');
            expect((await managerB.remove(model.id)).phase).toBe('idle');
        } finally {
            releaseStream();
            await managerA.shutdown();
            await managerB.shutdown();
            await rm(sharedDir, { recursive: true, force: true });
        }
    });

    it('reclaims a stale lock file left behind by a dead process', async () => {
        const sharedDir = await mkdtemp(path.join(os.tmpdir(), 'quenderin-speech-stale-lock-'));
        const lockFile = installedModelPath(sharedDir, model) + '.lock';
        await writeFile(lockFile, JSON.stringify({ pid: 999_999_999, token: 'dead', createdAt: 0 }), { mode: 0o600 });
        const fetch = vi.fn<SpeechDownloadFetch>().mockResolvedValue(httpFixture(200, fixtureBytes));
        const manager = new SpeechDownloadManager({
            catalog: { ...catalog, curatedModels: [model] },
            modelsDir: sharedDir, pinnedEngineVersion: '0.4.1', fetchImpl: fetch, fs: speechDownloadFs,
            sleep: async () => {},
        });
        managers.push(manager);
        try {
            await manager.start(model.id);
            await completes(manager, 'installed');
            expect(await readFile(installedModelPath(sharedDir, model))).toEqual(fixtureBytes);
        } finally {
            await manager.shutdown();
            await rm(sharedDir, { recursive: true, force: true });
        }
    });

    it('serializes multiple concurrent process contenders after abrupt owner death without unlinking the lock file', async () => {
        const sharedDir = await mkdtemp(path.join(os.tmpdir(), 'quenderin-speech-multiprocess-lock-'));
        const lockFile = installedModelPath(sharedDir, model) + '.lock';
        const moduleUrl = new URL('../src/services/speech/downloadManager.ts', import.meta.url).href;

        const spawnWorker = (mode: 'owner' | 'contender') => {
            const script = mode === 'owner'
                ? `(async () => {
                    const { speechDownloadFs } = await import(${JSON.stringify(moduleUrl)});
                    const lock = await speechDownloadFs.acquireLock(${JSON.stringify(lockFile)});
                    if (!lock) { process.stdout.write('BUSY\\n'); process.exit(2); }
                    process.stdout.write('HELD:' + process.pid + '\\n');
                    setInterval(() => {}, 10_000);
                })().catch(err => { console.error(err); process.exit(1); });`
                : `(async () => {
                    const { speechDownloadFs } = await import(${JSON.stringify(moduleUrl)});
                    process.stdout.write('READY\\n');
                    await new Promise(resolve => {
                        process.stdin.once('data', () => resolve(undefined));
                        process.stdin.once('end', () => resolve(undefined));
                    });
                    const lock = await speechDownloadFs.acquireLock(${JSON.stringify(lockFile)});
                    if (!lock) { process.stdout.write('BUSY\\n'); process.exit(0); }
                    process.stdout.write('WON\\n');
                    await new Promise(resolve => setTimeout(resolve, 600));
                    await lock.release();
                    process.exit(0);
                })().catch(err => { console.error(err); process.exit(1); });`;
            return spawn(process.execPath, ['--import', 'tsx', '-e', script], {
                cwd: path.resolve(import.meta.dirname, '..'),
                stdio: ['pipe', 'pipe', 'pipe'],
            });
        };

        try {
            const owner = spawnWorker('owner');
            const ownerPid = await new Promise<number>((resolve, reject) => {
                let out = '';
                let err = '';
                owner.stdout.on('data', chunk => {
                    out += chunk.toString();
                    const match = out.match(/HELD:(\d+)\n/);
                    if (match) resolve(Number(match[1]));
                });
                owner.stderr.on('data', chunk => { err += chunk.toString(); });
                owner.once('exit', code => reject(new Error(`Owner exited early (${code}): ${err}`)));
            });
            expect(ownerPid).toBe(owner.pid);

            const inodeBefore = await lstat(lockFile, { bigint: true });

            // While owner is alive, another OS process cannot acquire the lock.
            const liveContenderResult = await new Promise<string>((resolve, reject) => {
                const child = spawnWorker('contender');
                let out = '';
                let err = '';
                let releasedBarrier = false;
                child.stdout.on('data', chunk => {
                    out += chunk.toString();
                    if (!releasedBarrier && out.includes('READY\n')) {
                        releasedBarrier = true;
                        child.stdin.end('GO\n');
                    }
                });
                child.stderr.on('data', chunk => { err += chunk.toString(); });
                child.once('exit', code => code === 0 ? resolve(out.replace('READY\n', '').trim()) : reject(new Error(`Contender failed (${code}): ${err}`)));
            });
            expect(liveContenderResult).toBe('BUSY');

            // Boot 6 contenders up to the barrier BEFORE killing the owner, then release all 6 simultaneously.
            const contenders = Array.from({ length: 6 }, () => {
                const child = spawnWorker('contender');
                let out = '';
                let err = '';
                const ready = new Promise<void>((resolve, reject) => {
                    child.stdout.on('data', chunk => {
                        out += chunk.toString();
                        if (out.includes('READY\n')) resolve();
                    });
                    child.stderr.on('data', chunk => { err += chunk.toString(); });
                    child.once('exit', code => reject(new Error(`Contender exited before barrier (${code}): ${err}`)));
                });
                const done = new Promise<string>((resolve, reject) => {
                    child.once('exit', code => code === 0
                        ? resolve(out.replace('READY\n', '').trim())
                        : reject(new Error(`Contender failed (${code}): ${err}`)));
                });
                return { child, ready, done };
            });
            await Promise.all(contenders.map(c => c.ready));

            // Abruptly kill the owner process; the kernel releases the flock immediately on EOF/exit.
            const ownerExited = new Promise<void>(resolve => owner.once('exit', () => resolve()));
            process.kill(ownerPid, 'SIGKILL');
            await ownerExited;
            // Brief yield so the kernel EOF wakes the lock helper process before all 6 contenders race.
            await new Promise(resolve => setTimeout(resolve, 25));

            // Release all 6 already-booted contenders at the exact same instant.
            for (const c of contenders) c.child.stdin.end('GO\n');
            const results = await Promise.all(contenders.map(c => c.done));

            expect(results.filter(r => r === 'WON')).toHaveLength(1);
            expect(results.filter(r => r === 'BUSY')).toHaveLength(5);

            // Lock file remained in place with the exact same inode (never unlinked).
            const inodeAfter = await lstat(lockFile, { bigint: true });
            expect(inodeAfter.dev).toBe(inodeBefore.dev);
            expect(inodeAfter.ino).toBe(inodeBefore.ino);

            // After the winner released cleanly, this process can acquire and release the lock.
            const lock = await speechDownloadFs.acquireLock!(lockFile);
            expect(lock).not.toBeNull();
            await lock!.release();
        } finally {
            await rm(sharedDir, { recursive: true, force: true });
        }
    }, 20_000);

    it('classifies a locked preflight error, releases the lock, drains the next queued job, and allows retry', async () => {
        const releaseSpy = vi.fn(async () => {});
        const acquireLock = vi.fn(async () => ({ release: releaseSpy }));
        const disk = speechFsFixture();
        const originalStat = disk.fs.stat.bind(disk.fs);
        let finalStatCalls = 0;
        let failLockedPreflight = true;
        const fsWithPreflightFault = {
            ...disk.fs,
            acquireLock,
            async stat(filePath: string) {
                if (filePath === final && failLockedPreflight) {
                    finalStatCalls++;
                    // Call 1 is start()'s unlocked check (returns null to enqueue).
                    // Call 2 is download()'s locked checkInstalled preflight.
                    if (finalStatCalls === 2) {
                        throw Object.assign(new Error('permission denied on model path'), { code: 'EACCES' });
                    }
                }
                return originalStat(filePath);
            },
        };
        const unhandled: unknown[] = [];
        const onUnhandled = (reason: unknown) => { unhandled.push(reason); };
        process.on('unhandledRejection', onUnhandled);
        const { manager, fetch } = setup({ fs: fsWithPreflightFault, maxConcurrent: 1 });
        fetch.mockImplementation(async () => httpFixture(200, fixtureBytes));
        try {
            await manager.start(model.id);
            await manager.start(second.id);

            // First job reaches terminal error state (never stranded in queued) and releases its lock.
            const failed = await completes(manager, 'error');
            expect(failed.error?.kind).toBe('permission');
            expect(releaseSpy).toHaveBeenCalled();

            // Second queued job automatically drains and finishes cleanly.
            await vi.waitFor(() => expect(manager.snapshot(second.id)?.phase).toBe('installed'));
            expect(unhandled).toEqual([]);

            // Subsequent retry creates new work instead of returning a stale queued snapshot.
            failLockedPreflight = false;
            const retried = await manager.retry(model.id);
            expect(retried.phase).toBe('queued');
            await completes(manager, 'installed');
        } finally {
            process.off('unhandledRejection', onUnhandled);
        }
    });
});

describe('speech artifact transport redirect policy', () => {
    function redirectResponse(status: number, location?: string): Response {
        const headers = new Headers();
        if (location !== undefined) headers.set('location', location);
        return new Response('redirecting', { status, headers });
    }

    it('follows bounded HTTPS redirects across allowed Hugging Face artifact hosts', async () => {
        const calls: { url: string; init?: RequestInit }[] = [];
        const rawFetch: RawSpeechFetch = async (url, init) => {
            calls.push({ url, init });
            if (calls.length === 1) return redirectResponse(302, '/rel/redirect.gguf');
            if (calls.length === 2) return redirectResponse(307, 'https://cas-bridge.xethub.hf.co/blobs/abc');
            if (calls.length === 3) return redirectResponse(302, 'https://cdn-lfs-us-1.hf.co/repos/final.gguf');
            return new Response(fixtureBytes, { status: 206, headers: { 'content-range': 'bytes 0-28/29' } });
        };
        const transport = createSpeechArtifactFetch(rawFetch);
        const reply = await transport(modelDownloadUrl(model), {
            headers: { Range: 'bytes=0-', 'Accept-Encoding': 'identity', Authorization: 'Bearer should-not-forward' },
        });
        expect(reply.status).toBe(206);
        expect(calls.map(c => c.url)).toEqual([
            modelDownloadUrl(model),
            'https://huggingface.co/rel/redirect.gguf',
            'https://cas-bridge.xethub.hf.co/blobs/abc',
            'https://cdn-lfs-us-1.hf.co/repos/final.gguf',
        ]);
        for (const call of calls) {
            expect(call.init?.redirect).toBe('manual');
            expect(call.init?.credentials).toBe('omit');
            expect(call.init?.headers).toEqual({ Range: 'bytes=0-', 'Accept-Encoding': 'identity' });
        }
        await reply.discard?.();
    });

    it.each([
        ['HTTP downgrade', 'http://huggingface.co/model.gguf'],
        ['external host', 'https://evil.example/model.gguf'],
        ['lookalike host', 'https://huggingface.co.evil.example/model.gguf'],
        ['loopback IP', 'https://127.0.0.1/model.gguf'],
        ['non-standard port', 'https://huggingface.co:8443/model.gguf'],
        ['embedded credentials', 'https://user:pass@huggingface.co/model.gguf'],
    ])('blocks %s redirects before contacting the destination', async (_label, target) => {
        const rawFetch = vi.fn<RawSpeechFetch>().mockResolvedValueOnce(redirectResponse(302, target));
        const transport = createSpeechArtifactFetch(rawFetch);
        await expect(transport(modelDownloadUrl(model), {})).rejects.toMatchObject({
            code: 'network', retryable: false,
        });
        expect(rawFetch).toHaveBeenCalledTimes(1);
        expect(() => assertAllowedSpeechArtifactUrl(target)).toThrow();
    });

    it('rejects missing Location headers and redirect loops without retrying', async () => {
        const missingLoc = vi.fn<RawSpeechFetch>().mockResolvedValue(redirectResponse(302));
        await expect(createSpeechArtifactFetch(missingLoc)(modelDownloadUrl(model), {})).rejects.toMatchObject({
            code: 'network', retryable: false,
        });

        const loopFetch = vi.fn<RawSpeechFetch>().mockImplementation(async () =>
            redirectResponse(302, 'https://huggingface.co/loop'));
        const disk = speechFsFixture();
        const manager = new SpeechDownloadManager({
            catalog: { ...catalog, curatedModels: [model] },
            modelsDir: '/fixture/speech', pinnedEngineVersion: '0.4.1',
            fetchImpl: createSpeechArtifactFetch(loopFetch), fs: disk.fs,
            sleep: async () => {}, retry: { maxAttempts: 3, baseDelayMs: 1, maxDelayMs: 5 },
        });
        await manager.start(model.id);
        await vi.waitFor(() => expect(manager.snapshot(model.id)?.phase).toBe('error'));
        // 1 initial request + 5 allowed hops = 6 calls total, zero retry attempts.
        expect(loopFetch).toHaveBeenCalledTimes(6);
        await manager.shutdown();
    });
});
