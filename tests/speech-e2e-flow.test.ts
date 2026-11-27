import { once } from 'node:events';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import type { Server } from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { PassThrough } from 'node:stream';
import { catalog } from '@handy-computer/models';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createApp } from '../src/app.js';
import type { HexSpeechAdapter } from '../src/services/hexSpeechAdapter.js';
import { installedModelPath, modelDownloadUrl } from '../src/services/speech/catalog.js';
import { speechDownloadFs, SpeechDownloadManager, type SpeechDownloadFetch } from '../src/services/speech/downloadManager.js';
import { SpeechSettingsStore } from '../src/services/speech/speechSettings.js';
import { transcribeSpeech } from '../src/services/speech/transcribe.js';
import type { SpeechDownloadSnapshot, SpeechModelListResponse } from '../src/services/speech/types.js';
import { localRequest } from './helpers/localHttp.js';
import { fixtureBytes, fixtureModel, httpFixture, wavFixture } from './helpers/speechFixtures.js';

const token = 'speech-flow-fixture';
const model = fixtureModel();
const fixtureCatalog = {
    ...catalog,
    curatedModels: catalog.curatedModels.map(row => row.id === model.id ? model : row),
};
const modelRoute = `/downloads/${model.id}`;
const prefixBytes = fixtureBytes.subarray(0, 5);
const transcript = {
    text: 'Send the weekly update.', rawText: 'send the weekly update', language: 'en',
    modelId: model.id, backend: 'transcribe.cpp', durationMs: 25, truncated: false, segments: [],
};

describe('local speech across the dashboard API', () => {
    let directory: string;
    let finalFile: string;
    let partFile: string;
    let server: Server;
    let base: string;
    let downloads: SpeechDownloadManager;
    let events: SpeechDownloadSnapshot[];
    let body: PassThrough;
    const fetchArtifact = vi.fn<SpeechDownloadFetch>();
    const rename = vi.fn(speechDownloadFs.rename);
    const adapter = { transcribe: vi.fn<HexSpeechAdapter['transcribe']>() };

    beforeEach(async () => {
        directory = await mkdtemp(path.join(os.tmpdir(), 'quenderin-speech-flow-'));
        finalFile = installedModelPath(directory, model);
        partFile = finalFile + '.part';
        body = new PassThrough();
        events = [];
        fetchArtifact.mockReset().mockResolvedValue(httpFixture(200, fixtureBytes));
        rename.mockReset();
        adapter.transcribe.mockReset().mockResolvedValue(transcript);
        const pinnedEngineVersion = '0.4.1';
        const maxAudioBytes = 128;
        let tick = 0;
        downloads = new SpeechDownloadManager({
            catalog: fixtureCatalog, modelsDir: directory, pinnedEngineVersion, fetchImpl: fetchArtifact,
            fs: { ...speechDownloadFs, rename }, onProgress: event => events.push(event), now: () => { tick += 1000; return tick; },
        });
        const settings = new SpeechSettingsStore({ filePath: path.join(directory, 'settings.json') });
        const app = createApp(undefined, undefined, undefined, undefined, undefined, token, {
            catalog: fixtureCatalog, pinnedEngineVersion, maxAudioBytes, downloads, settings,
            transcribe: (request, signal) => transcribeSpeech({
                catalog: fixtureCatalog, pinnedEngineVersion, maxAudioBytes, modelsDir: directory, adapter, signal,
            }, request),
        });
        server = app.listen(0, '127.0.0.1');
        await once(server, 'listening');
        const address = server.address();
        if (!address || typeof address === 'string') throw Error('Missing loopback test address.');
        base = `http://127.0.0.1:${address.port}/api/speech`;
    });

    afterEach(async () => {
        body.destroy();
        await downloads.shutdown();
        await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
        await rm(directory, { recursive: true, force: true });
    });

    const request = (route: string, method = 'GET', json?: object) => localRequest(base + route, {
        method, body: json === undefined ? undefined : JSON.stringify(json), headers: { 'X-Auth-Token': token },
    });
    const start = () => request('/downloads', 'POST', { modelId: model.id });
    const status = async (expected: Partial<SpeechDownloadSnapshot>) => {
        await vi.waitFor(async () => {
            const reply = await request(modelRoute);
            expect(reply.status).toBe(200);
            expect(reply.json()).toMatchObject(expected);
        });
    };
    function streamDownload() {
        fetchArtifact.mockResolvedValueOnce({ ...httpFixture(200, null), body });
        body.write(prefixBytes);
    }

    it('lists, downloads, verifies and installs the chosen model before transcribing a WAV', async () => {
        const listed = await localRequest(base + '/models');
        expect(listed.status).toBe(200);
        const { models, recommendedModelId } = listed.json() as SpeechModelListResponse;
        expect(models).toHaveLength(29);
        expect(recommendedModelId).toBe(model.id);
        expect(models.find(row => row.model.id === recommendedModelId)).toMatchObject({ installed: false });

        streamDownload();
        const started = await start();
        expect(started.status).toBe(202);
        expect(started.json()).toMatchObject({ phase: 'queued', modelId: recommendedModelId });
        const choice = { modelId: recommendedModelId, voiceEnabled: true, autoSend: true };
        const saved = await request('/settings', 'PUT', choice);
        expect(saved.status).toBe(200);
        expect(saved.json()).toMatchObject(choice);

        const wav = wavFixture();
        const dictate = () => localRequest(base + '/transcribe?language=en', {
            method: 'POST', body: wav, headers: { 'X-Auth-Token': token, 'Content-Type': 'audio/wav' },
        });
        await status({ phase: 'downloading', downloadedBytes: prefixBytes.length });
        expect(await readFile(partFile)).toEqual(prefixBytes);
        await expect(readFile(finalFile)).rejects.toMatchObject({ code: 'ENOENT' });
        const tooEarly = await dictate();
        expect(tooEarly.status).toBe(409);
        expect(tooEarly.json()).toMatchObject({ code: 'model-not-installed' });
        expect(adapter.transcribe).not.toHaveBeenCalled();

        body.end(fixtureBytes.subarray(prefixBytes.length));
        await status({ phase: 'installed', percent: 100 });
        expect(events.filter(event => event.phase === 'verifying')).toEqual([
            expect.objectContaining({ downloadedBytes: fixtureBytes.length }),
        ]);
        expect(rename).toHaveBeenCalledExactlyOnceWith(partFile, finalFile);
        expect(await readFile(finalFile)).toEqual(fixtureBytes);
        await expect(readFile(partFile)).rejects.toMatchObject({ code: 'ENOENT' });
        expect(fetchArtifact).toHaveBeenCalledExactlyOnceWith(modelDownloadUrl(model), expect.any(Object));

        const result = await dictate();
        expect(result.status).toBe(200);
        expect(result.json()).toEqual({ ...transcript, autoSend: true });
        expect(adapter.transcribe).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({
            model: model.id, directory, wav, language: 'en', signal: expect.any(AbortSignal),
        }));
    });

    it.each([206, 416])('recovers an on-disk partial through the API after HTTP %s', async response => {
        await writeFile(partFile, prefixBytes);
        await status({ phase: 'paused', downloadedBytes: prefixBytes.length });
        const offset = prefixBytes.length;
        fetchArtifact.mockResolvedValueOnce(response === 416 ? httpFixture(416, null) :
            httpFixture(206, fixtureBytes.subarray(offset), {
                'content-range': `bytes ${offset}-${fixtureBytes.length - 1}/${fixtureBytes.length}`,
            }));

        const resumed = await request(`${modelRoute}/resume`, 'POST');
        expect(resumed.status).toBe(200);
        expect(resumed.json()).toMatchObject({ phase: 'queued' });
        await status({ phase: 'installed' });
        expect(fetchArtifact.mock.calls.map(([, init]) => init.headers?.Range)).toEqual(
            response === 416 ? [`bytes=${offset}-`, undefined] : [`bytes=${offset}-`],
        );
        expect(await readFile(finalFile)).toEqual(fixtureBytes);
    });

    it('discards a checksum failure and retries from byte zero', async () => {
        fetchArtifact.mockResolvedValueOnce(httpFixture(200, Buffer.alloc(fixtureBytes.length)));
        expect((await start()).status).toBe(202);
        await status({ phase: 'error', error: expect.objectContaining({ kind: 'checksum-mismatch' }) });
        expect(rename).not.toHaveBeenCalled();
        await expect(readFile(partFile)).rejects.toMatchObject({ code: 'ENOENT' });
        expect(fetchArtifact).toHaveBeenCalledTimes(1);

        expect((await request(`${modelRoute}/retry`, 'POST')).status).toBe(200);
        await status({ phase: 'installed' });
        expect(fetchArtifact.mock.calls[1][1].headers?.Range).toBeUndefined();
        expect(await readFile(finalFile)).toEqual(fixtureBytes);
    });

    it('reports a full disk at final rename and installs the verified partial on retry', async () => {
        rename.mockRejectedValueOnce(Object.assign(new Error('fixture disk full'), { code: 'ENOSPC' }));
        expect((await start()).status).toBe(202);
        await status({ phase: 'error', error: expect.objectContaining({ kind: 'disk-full' }) });
        await expect(readFile(finalFile)).rejects.toMatchObject({ code: 'ENOENT' });
        expect(await readFile(partFile)).toEqual(fixtureBytes);

        expect((await request(`${modelRoute}/retry`, 'POST')).status).toBe(200);
        await status({ phase: 'installed' });
        expect(fetchArtifact).toHaveBeenCalledTimes(1);
        expect(await readFile(finalFile)).toEqual(fixtureBytes);
    });

    it('cancels an active stream, deletes its partial and starts cleanly again', async () => {
        streamDownload();
        expect((await start()).status).toBe(202);
        await status({ phase: 'downloading', downloadedBytes: prefixBytes.length });
        const cancelled = await request(`${modelRoute}/cancel`, 'POST');
        expect(cancelled.status).toBe(200);
        expect(cancelled.json()).toMatchObject({ phase: 'idle', downloadedBytes: 0 });
        expect(fetchArtifact.mock.calls[0][1].signal?.aborted).toBe(true);
        await expect(readFile(partFile)).rejects.toMatchObject({ code: 'ENOENT' });
        expect(rename).not.toHaveBeenCalled();

        expect((await start()).status).toBe(202);
        await status({ phase: 'installed' });
        expect(fetchArtifact.mock.calls[1][1].headers?.Range).toBeUndefined();
        expect(await readFile(finalFile)).toEqual(fixtureBytes);
    });
});
