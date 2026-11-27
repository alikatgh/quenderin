import { getEventListeners, EventEmitter, once } from 'node:events';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { catalog } from '@handy-computer/models';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import WebSocket from 'ws';
import { createApp } from '../src/app.js';
import { WebSocketManager } from '../src/websocket/index.js';
import { installedModelPath } from '../src/services/speech/catalog.js';
import { SpeechDownloadManager, type SpeechDownloadFetch } from '../src/services/speech/downloadManager.js';
import { SpeechSettingsStore } from '../src/services/speech/speechSettings.js';
import type { SpeechTranscriptionRequest, SpeechTranscriptionResponse } from '../src/services/speech/types.js';
import { localRequest } from './helpers/localHttp.js';
import { fixtureBytes, fixtureModel, httpFixture, speechFsFixture, wavFixture } from './helpers/speechFixtures.js';

const TOKEN = 'fixture-token';
const model = fixtureModel();
const future = fixtureModel({ id: 'future-model', minEngine: '1.0.0' });
const fixtureCatalog = {
    ...catalog, curatedModels: catalog.curatedModels.map(entry => entry.id === model.id ? model : entry).concat(future),
};
const prefix = '/api/speech';

describe('dashboard speech routes', () => {
    let dir: string;
    let server: ReturnType<ReturnType<typeof createApp>['listen']>;
    let base: string;
    let downloads: SpeechDownloadManager;
    let settings: SpeechSettingsStore;
    let fetch: ReturnType<typeof vi.fn<SpeechDownloadFetch>>;
    let disk: ReturnType<typeof speechFsFixture>;
    let transcribe: ReturnType<typeof vi.fn<(request: SpeechTranscriptionRequest, signal: AbortSignal) => Promise<SpeechTranscriptionResponse>>>;
    let clients: WebSocket[];

    beforeEach(async () => {
        clients = [];
        dir = await fs.mkdtemp(path.join(os.tmpdir(), 'quenderin-speech-api-test-'));
        settings = new SpeechSettingsStore({ filePath: path.join(dir, 'settings.json') });
        disk = speechFsFixture();
        fetch = vi.fn<SpeechDownloadFetch>().mockResolvedValue(httpFixture(200, fixtureBytes));
        downloads = new SpeechDownloadManager({
            catalog: fixtureCatalog, pinnedEngineVersion: '0.4.1', modelsDir: dir, fetchImpl: fetch, fs: disk.fs,
        });
        transcribe = vi.fn(async (request: SpeechTranscriptionRequest): Promise<SpeechTranscriptionResponse> => ({
            text: 'Local transcript', rawText: 'Local transcript', modelId: request.modelId, language: request.language ?? '',
            backend: 'transcribe.cpp', durationMs: 1, truncated: false, autoSend: !!request.autoSend, segments: [],
        }));
        const app = createApp(undefined, undefined, undefined, undefined, undefined, TOKEN, {
            catalog: fixtureCatalog, pinnedEngineVersion: '0.4.1', maxAudioBytes: 128, downloads, settings, transcribe,
        });
        server = app.listen(0, '127.0.0.1');
        await once(server, 'listening');
        const address = server.address();
        if (!address || typeof address === 'string') throw Error('Missing test server address.');
        base = `http://127.0.0.1:${address.port}`;
    });
    afterEach(async () => {
        await Promise.all(clients.map(async ws => {
            if (ws.readyState === WebSocket.CLOSED) return;
            ws.terminate();
            await once(ws, 'close');
        }));
        await new Promise<void>(resolve => { server.close(() => resolve()); });
        await downloads.shutdown();
        await fs.rm(dir, { recursive: true, force: true });
    });

    function request(route: string, method = 'GET', body?: unknown, authorized = true) {
        return localRequest(base + prefix + route, {
            method, body: body === undefined ? undefined : JSON.stringify(body),
            headers: authorized ? { 'X-Auth-Token': TOKEN } : {},
        });
    }
    function wav(body: Buffer, query = '', length = body.length) {
        return localRequest(base + prefix + '/transcribe' + query, {
            method: 'POST', body,
            headers: { 'Content-Length': String(length), 'Content-Type': 'audio/wav', 'X-Auth-Token': TOKEN },
        });
    }

    it('lists all curated rows, measured picks and the unsupported-engine state', async () => {
        const reply = await request('/models', 'GET', undefined, false);
        expect(reply.status).toBe(200);
        const result = reply.json();
        expect(result).toMatchObject({ runtimeEngineVersion: '0.4.1', recommendedModelId: model.id, accurateModelId: 'Qwen3-ASR-1.7B' });
        expect(result.models).toHaveLength(30);
        expect(result.models.at(-1)).toMatchObject({ model: { id: future.id }, engine: { compatibility: 'needs-newer-engine' } });
    });

    it('serves the shipped Handy notices as text', async () => {
        const credits = await request('/credits', 'GET', undefined, false);
        expect(credits.status).toBe(200);
        expect(credits.header('Content-Type')).toMatch(/^text\/plain/);
        expect(credits.body).toContain('Copyright (c) 2025 CJ Pais');
        expect(credits.body).toContain('@handy-computer/models');
    });

    it('requires authorization for settings, progress and mutations regardless of URL case', async () => {
        expect((await request('/settings', 'GET', undefined, false)).status).toBe(401);
        expect((await request('/SETTINGS', 'HEAD', undefined, false)).status).toBe(401);
        expect((await request('/downloads', 'GET', undefined, false)).status).toBe(401);
        expect((await request('/DOWNLOADS', 'POST', { modelId: model.id }, false)).status).toBe(401);
        expect((await request('/transcribe', 'POST', {}, false)).status).toBe(401);
        expect((await localRequest(base + '/API/SPEECH/settings')).status).toBe(401);
        expect(fetch).not.toHaveBeenCalled();
    });

    it('persists valid settings and rejects unknown ids, keys and types', async () => {
        const selection = { modelId: model.id, voiceEnabled: true, autoSend: true };
        const saved = await request('/settings', 'PUT', selection);
        expect(saved.status).toBe(200);
        expect(saved.json()).toMatchObject(selection);
        expect((await request('/settings')).json()).toMatchObject(selection);
        for (const patch of [{ modelId: 'missing' }, { defaultMic: true }, { autoSend: 2 }]) {
            expect((await request('/settings', 'PUT', patch)).status).toBe(400);
        }
        expect((await request('/settings', 'PUT', { modelId: future.id })).json()).toMatchObject({ code: 'unsupported-engine' });
    });

    it('starts, tracks, installs and removes a verified fixture download', async () => {
        expect((await request('/downloads/' + model.id)).status).toBe(404);
        const started = await request('/downloads', 'POST', { modelId: model.id });
        expect(started.status).toBe(202);
        expect(started.json()).toMatchObject({ phase: 'queued', modelId: model.id });
        await vi.waitFor(() => expect(downloads.snapshot(model.id)?.phase).toBe('installed'));
        expect((await request('/downloads/' + model.id)).json()).toMatchObject({ phase: 'installed', percent: 100 });
        expect((await request('/downloads', 'POST', { modelId: model.id })).json()).toMatchObject({ code: 'already-installed' });
        await settings.update({ modelId: model.id, voiceEnabled: true });
        expect((await request('/models/' + model.id, 'DELETE')).json()).toMatchObject({
            snapshot: { phase: 'idle' }, settings: { modelId: null, voiceEnabled: false },
        });
        expect(disk.files.size).toBe(0);
    });

    it('pauses, resumes and cancels background requests through authenticated endpoints', async () => {
        fetch.mockImplementation(() => new Promise(() => {}));
        const route = '/downloads/' + model.id;
        await request('/downloads', 'POST', { modelId: model.id });
        expect((await request(route + '/pause', 'POST')).json()).toMatchObject({ phase: 'paused' });
        expect((await request(route + '/resume', 'POST')).json()).toMatchObject({ phase: 'queued' });
        expect((await request(route + '/cancel', 'POST')).json()).toMatchObject({ phase: 'idle' });
    });

    it('returns typed unknown-model and unsupported-engine errors', async () => {
        const missing = await request('/downloads', 'POST', { modelId: 'unknown' });
        const unsupported = await request('/downloads', 'POST', { modelId: future.id });
        expect(missing.status).toBe(404);
        expect(missing.json()).toMatchObject({ code: 'unknown-model' });
        expect(unsupported.status).toBe(409);
        expect(unsupported.json()).toMatchObject({ code: 'unsupported-engine' });
        expect(fetch).not.toHaveBeenCalled();
    });

    it('validates WAV MIME, bytes and declared size at the HTTP boundary', async () => {
        expect((await request('/transcribe', 'POST', {})).status).toBe(415);
        expect((await wav(Buffer.from('invalid'))).status).toBe(415);
        const oversized = await wav(wavFixture(), '', 129);
        expect(oversized.status).toBe(413);
        expect(oversized.json()).toMatchObject({ code: 'audio-too-large' });
        expect((await wav(wavFixture(), '?modelId=' + future.id)).json()).toMatchObject({ code: 'unsupported-engine' });
        expect(transcribe).not.toHaveBeenCalled();
    });

    it('requires the saved model to be enabled and verified before using local speech', async () => {
        const audio = wavFixture();
        const query = '?modelId=' + model.id + '&language=en';
        expect((await wav(audio, query)).json()).toMatchObject({ code: 'voice-disabled' });
        await settings.update({ modelId: model.id, voiceEnabled: true, autoSend: true });
        expect((await wav(audio, query)).json()).toMatchObject({ code: 'model-not-installed' });
        disk.put(installedModelPath(dir, model), fixtureBytes);
        const reply = await wav(audio, query);
        expect(reply.status).toBe(200);
        expect(reply.json()).toMatchObject({ text: 'Local transcript', backend: 'transcribe.cpp', autoSend: true });
        expect(transcribe).toHaveBeenCalledExactlyOnceWith({ wav: audio, modelId: model.id, language: 'en', autoSend: true }, expect.any(AbortSignal));
    });

    it('streams real progress frames to authenticated dashboard WebSockets', async () => {
        const llm = Object.assign(new EventEmitter(), { isCurrentlyGenerating: () => ({ isGenerating: false }) });
        new WebSocketManager(server, {} as never, new EventEmitter() as never, llm as never, new EventEmitter() as never,
            undefined, TOKEN, undefined, downloads);
        const ws = new WebSocket(base.replace('http:', 'ws:') + '/ws?token=' + TOKEN, { origin: base });
        clients.push(ws);
        const frames: string[] = [];
        ws.on('message', data => frames.push(String(data)));
        await once(ws, 'open');
        const listeners = getEventListeners(llm, 'model_download_progress');
        expect(listeners).toHaveLength(1);
        await request('/downloads', 'POST', { modelId: model.id });
        await vi.waitFor(() => expect(frames.map(f => JSON.parse(f))).toContainEqual(expect.objectContaining({
            type: 'speech_download_progress', snapshot: expect.objectContaining({ phase: 'installed', modelId: model.id }),
        })));
    });
});
