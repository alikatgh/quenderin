import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import http from 'node:http';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import type { SpawnOptions } from 'node:child_process';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
    HexLoopbackClient,
    HexSpeechAdapter,
    applyVocabularySpelling,
    formatDictationTranscript,
    validateWavBuffer,
    type SpeechModelCatalog,
    type SpeechRuntimeLock,
} from '../src/services/hexSpeechAdapter.js';
import { VoiceService } from '../src/services/voice.service.js';
import { nativeWorkloads } from '../src/services/nativeWorkloads.js';
import logger from '../src/utils/logger.js';

function createPcm16MonoWav(samples: number[], sampleRate = 16000): Buffer {
    const dataBytes = samples.length * 2;
    const buf = Buffer.alloc(44 + dataBytes);
    buf.write('RIFF', 0);
    buf.writeUInt32LE(36 + dataBytes, 4);
    buf.write('WAVE', 8);
    buf.write('fmt ', 12);
    buf.writeUInt32LE(16, 16);
    buf.writeUInt16LE(1, 20);
    buf.writeUInt16LE(1, 22);
    buf.writeUInt32LE(sampleRate, 24);
    buf.writeUInt32LE(sampleRate * 2, 28);
    buf.writeUInt16LE(2, 32);
    buf.writeUInt16LE(16, 34);
    buf.write('data', 36);
    buf.writeUInt32LE(dataBytes, 40);
    for (let i = 0; i < samples.length; i++) {
        buf.writeInt16LE(samples[i], 44 + i * 2);
    }
    return buf;
}

const PINNED_REV = '60bed89dab84f7c1fddc3a17ad7fa8a27ddfba19';
const PINNED_HEX = 'fd2fafc91b67754065af17b9db70bb1cbbc13bb1';

describe('Hex & transcribe.cpp speech integration', () => {
    let tmpDir: string;
    let catalog: SpeechModelCatalog;
    let runtimeLock: SpeechRuntimeLock;
    let wavPath: string;
    let modelBytes: Buffer;
    let vadBytes: Buffer;

    beforeEach(async () => {
        tmpDir = await fs.promises.realpath(await fs.promises.mkdtemp(path.join(os.tmpdir(), 'quenderin-speech-test-')));
        modelBytes = Buffer.from('GGUF_PARAKEET_FIXTURE');
        vadBytes = Buffer.from('GGUF_SILERO_VAD_FIXTURE');
        await fs.promises.writeFile(path.join(tmpDir, 'parakeet-unified-en-0.6b-Q8_0.gguf'), modelBytes);
        await fs.promises.writeFile(path.join(tmpDir, 'silero-vad-v6.2-F32.gguf'), vadBytes);
        wavPath = path.join(tmpDir, 'sample.wav');
        await fs.promises.writeFile(wavPath, createPcm16MonoWav([0, 1200, -1200, 300, -300, 0], 16000));

        runtimeLock = {
            version: 1,
            abiVersion: 1,
            revision: PINNED_REV,
            engineVersion: '0.4.1',
            license: 'MIT',
            hex: {
                repository: 'https://github.com/anomalyco/hex.git',
                revision: PINNED_HEX,
                version: '3.4.0',
                localApiVersion: '2',
                license: 'MIT',
            },
            bounds: {
                maxAudioBytes: 64 * 1024 * 1024,
                sampleRateHz: 16000,
                maxThreads: 8,
                maxVocabularyTerms: 100,
                maxTermLength: 64,
                maxPromptBytes: 8192,
            },
        };

        catalog = {
            version: 1,
            status: 'experimental-source-integration-no-inference-validation',
            vad: {
                id: 'silero_vad_v6_2',
                label: 'Silero VAD v6.2',
                repo: 'handy-computer/silero-vad-v6.2-gguf',
                revision: 'a9b2d61c20ae4ddf3644edb34969e8185a485448',
                filename: 'silero-vad-v6.2-F32.gguf',
                localFilename: 'silero-vad-v6.2-F32.gguf',
                bytes: vadBytes.length,
                sha256: crypto.createHash('sha256').update(vadBytes).digest('hex'),
                architecture: 'silero_vad',
                variant: 'v6.2',
                license: 'MIT',
                access: 'public',
            },
            models: [
                {
                    id: 'parakeet_unified_en',
                    label: 'Parakeet Unified English',
                    engine: 'transcribe.cpp',
                    architecture: 'parakeet',
                    variant: 'tdt-0.6b-v2-unified-en',
                    localFilename: 'parakeet-unified-en-0.6b-Q8_0.gguf',
                    bytes: modelBytes.length,
                    sha256: crypto.createHash('sha256').update(modelBytes).digest('hex'),
                    languages: ['en'],
                    acceptsLanguageHint: true,
                    supportsLanguageDetection: false,
                    streams: true,
                    vocabularyUse: 'bias',
                    license: 'CC-BY-4.0',
                    access: 'public',
                },
                {
                    id: 'apple_speech',
                    label: 'Apple Speech',
                    engine: 'apple_speech',
                    architecture: 'apple_speech',
                    variant: 'macos',
                    localFilename: null,
                    bytes: null,
                    sha256: null,
                    languages: ['en', 'fr'],
                    acceptsLanguageHint: true,
                    supportsLanguageDetection: false,
                    streams: true,
                    vocabularyUse: 'replacement',
                    license: 'Apple System Framework',
                    access: 'system',
                },
            ],
        };
    });

    afterEach(async () => {
        vi.restoreAllMocks();
        await fs.promises.rm(tmpDir, { recursive: true, force: true });
    });

    it('loads the real bundled speech catalog with all 20 pinned Hex models and Silero VAD v6.2', () => {
        const adapter = new HexSpeechAdapter();
        expect(adapter.runtimeLock.abiVersion).toBe(1);
        expect(adapter.runtimeLock.hex.localApiVersion).toBe('2');
        expect(adapter.vad().id).toBe('silero_vad_v6_2');
        expect(adapter.models()).toHaveLength(20);
        expect(adapter.model('parakeet_unified_en').engine).toBe('transcribe.cpp');
        expect(adapter.model('apple_speech').engine).toBe('apple_speech');
    });

    it('verifies model and Silero VAD artifacts offline and rejects symlinks or hash mismatches', async () => {
        const adapter = new HexSpeechAdapter({ catalog, runtimeLock });
        const verified = await adapter.verify('parakeet_unified_en', tmpDir, { includeVad: true });
        expect(verified.vadVerified).toBe(true);
        expect(verified.bytes).toBe(modelBytes.length + vadBytes.length);

        await expect(adapter.verify('apple_speech', tmpDir)).rejects.toThrow(/apple_speech/);

        await fs.promises.writeFile(path.join(tmpDir, 'parakeet-unified-en-0.6b-Q8_0.gguf'), Buffer.from('CORRUPTED_LEN_MISMATCH!'));
        await expect(adapter.verify('parakeet_unified_en', tmpDir)).rejects.toThrow(/size or file identity|SHA-256 mismatch/);

        const linkDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'quenderin-speech-link-'));
        try {
            await fs.promises.symlink(
                path.join(tmpDir, 'silero-vad-v6.2-F32.gguf'),
                path.join(linkDir, 'silero-vad-v6.2-F32.gguf'),
            );
            await fs.promises.writeFile(path.join(linkDir, 'parakeet-unified-en-0.6b-Q8_0.gguf'), modelBytes);
            await expect(adapter.verify('parakeet_unified_en', linkDir, { includeVad: true }))
                .rejects.toThrow(/regular local file without symlinks/);
        } finally {
            await fs.promises.rm(linkDir, { recursive: true, force: true });
        }
    });

    it('formats dictation transcripts with vocabulary spelling, spoken punctuation, and French spacing', () => {
        const spelling = applyVocabularySpelling('open quanderin and run kromos with dmd2', [
            { term: 'Quenderin', phoneticHints: ['quanderin', 'quenderin'] },
            { term: 'Kromoss', phoneticHints: ['kromos'] },
            { term: 'DMD2', caseSensitive: false },
        ]);
        expect(spelling).toBe('open Quenderin and run Kromoss with DMD2');

        const formatted = formatDictationTranscript('um open quanderin comma then run kromos question mark', {
            removeFillerWords: true,
            spokenPunctuation: true,
            vocabulary: [{ term: 'Quenderin', phoneticHints: ['quanderin'] }, { term: 'Kromoss', phoneticHints: ['kromos'] }],
        });
        expect(formatted).toBe('open Quenderin, then run Kromoss?');

        const french = formatDictationTranscript('bonjour : comment ça va ?', {
            frenchSpacing: true,
        });
        expect(french).toBe('bonjour\u202F: comment ça va\u202F?');
    });

    it('rejects non-16kHz WAV buffers and connects cleanly to Hex loopback v2 HTTP/SSE protocol', async () => {
        expect(() => validateWavBuffer(createPcm16MonoWav([1, 2, 3], 48000))).toThrow(/16 kHz mono 16-bit PCM/);

        const token = 'hex-test-token-123';
        let sawPrepare = false;
        let sawWavBytes = 0;
        const server = http.createServer((req, res) => {
            if (req.headers.authorization !== `Bearer ${token}`) {
                res.statusCode = 401;
                res.end();
                return;
            }
            if (req.method === 'GET' && req.url === '/health') {
                res.setHeader('Content-Type', 'application/json');
                res.end(JSON.stringify({ status: 'ok', apiVersion: '2' }));
                return;
            }
            if (req.method === 'POST' && req.url === '/models/parakeet_unified_en/prepare') {
                sawPrepare = true;
                res.setHeader('Content-Type', 'text/event-stream');
                res.write('event: progress\ndata: {"status":"loading","progress":0.5}\n\n');
                res.end('event: done\ndata: {"status":"ok","progress":1}\n\n');
                return;
            }
            if (req.method === 'POST' && req.url?.startsWith('/transcriptions')) {
                const chunks: Buffer[] = [];
                req.on('data', chunk => chunks.push(chunk as Buffer));
                req.on('end', () => {
                    sawWavBytes = Buffer.concat(chunks).length;
                    res.setHeader('Content-Type', 'application/json');
                    res.end(JSON.stringify({
                        transcript: 'uh open quanderin status comma please',
                        durationMs: 42,
                        language: 'en',
                        segments: [{ startMs: 0, endMs: 42, text: 'uh open quanderin status comma please' }],
                    }));
                });
                return;
            }
            res.statusCode = 404;
            res.end();
        });

        await new Promise<void>(resolve => server.listen(0, '127.0.0.1', () => resolve()));
        const port = (server.address() as { port: number }).port;
        const discoveryPath = path.join(tmpDir, 'local-api.json');
        await fs.promises.writeFile(discoveryPath, JSON.stringify({ port, token, apiVersion: '2', pid: process.pid }));

        try {
            const client = await HexLoopbackClient.fromDiscoveryFile(discoveryPath);
            expect((await client.health()).status).toBe('ok');

            const adapter = new HexSpeechAdapter({ catalog, runtimeLock });
            const events: string[] = [];
            const res = await adapter.transcribeWithHexHost({
                model: 'parakeet_unified_en',
                wav: wavPath,
                hexDiscoveryPath: discoveryPath,
                prepareModel: true,
                onPrepareProgress: ev => events.push(ev.status),
                format: {
                    removeFillerWords: true,
                    spokenPunctuation: true,
                    vocabulary: [{ term: 'Quenderin', phoneticHints: ['quanderin'] }],
                    endWithPeriod: true,
                },
            });

            expect(sawPrepare).toBe(true);
            expect(sawWavBytes).toBeGreaterThan(44);
            expect(events).toEqual(['loading', 'ok']);
            expect(res.backend).toBe('hex-loopback-v2');
            expect(res.text).toBe('open Quenderin status, please.');
        } finally {
            await new Promise<void>(resolve => server.close(() => resolve()));
        }
    });

    it('parses embedded `hex service --embedded` handshake and refuses non-loopback endpoints', async () => {
        const fakeBin = path.join(tmpDir, 'hex');
        await fs.promises.writeFile(fakeBin, '#!/bin/sh\necho ok\n', { mode: 0o755 });

        const makeMockChild = (handshakeLine: string) => {
            const child = new EventEmitter() as EventEmitter & {
                stdout: PassThrough;
                stderr: PassThrough;
                exitCode: number | null;
                signalCode: NodeJS.Signals | null;
                kill: ReturnType<typeof vi.fn>;
                unref: ReturnType<typeof vi.fn>;
            };
            child.stdout = new PassThrough();
            child.stderr = new PassThrough();
            child.exitCode = null;
            child.signalCode = null;
            child.kill = vi.fn(() => {
                child.exitCode = 0;
                queueMicrotask(() => child.emit('close', 0, null));
                return true;
            });
            child.unref = vi.fn();
            queueMicrotask(() => child.stdout.write(handshakeLine + '\n'));
            return child;
        };

        await expect(HexLoopbackClient.launchEmbedded(fakeBin, {
            spawnProcess: () => makeMockChild(JSON.stringify({
                type: 'ready',
                url: 'https://evil.example:9000',
                token: 'secret',
                apiVersion: '2',
                pid: 123,
            })) as never,
        })).rejects.toThrow(/malformed JSON handshake|loopback/i);

        const spawnMock = vi.fn((_f: string, _a: string[], _o: SpawnOptions) => makeMockChild(JSON.stringify({
            type: 'ready',
            url: 'http://127.0.0.1:44444',
            token: 'secret-tok',
            apiVersion: '2',
            pid: 999,
        })) as never);
        const client = await HexLoopbackClient.launchEmbedded(fakeBin, { spawnProcess: spawnMock });
        expect(spawnMock).toHaveBeenCalledWith(fakeBin, ['service', '--embedded'], expect.objectContaining({ shell: false }));
        expect(client.baseUrl).toBe('http://127.0.0.1:44444');
        await client.close();
    });

    it('runs quenderin-speech-cli with version handshake, cancellation, and VoiceService command emission without logging transcripts', async () => {
        const cliScript = path.join(tmpDir, 'quenderin-speech-cli.mjs');
        await fs.promises.writeFile(cliScript, `#!/usr/bin/env node
import fs from 'node:fs';
const args = process.argv.slice(2);
if (args.includes('--version')) {
    console.log(JSON.stringify({ abiVersion: 1, revision: ${JSON.stringify(PINNED_REV)} }));
} else {
    const opts = {};
    for (let i = 0; i < args.length; i++) {
        if (args[i].startsWith('--') && args[i + 1] && !args[i + 1].startsWith('--')) opts[args[i]] = args[i + 1];
    }
    if (!opts['--model'] || !opts['--wav'] || !opts['--vad']) process.exit(2);
    console.log(JSON.stringify({
        ok: true,
        text: 'check quanderin release status',
        language: 'en',
        backend: 'cpu-fixture',
        durationMs: 18,
        truncated: false,
        segments: [{ startMs: 0, endMs: 18, text: 'check quanderin release status' }],
    }));
}
`, { mode: 0o755 });

        const infoSpy = vi.spyOn(logger, 'info');
        const adapter = new HexSpeechAdapter({ catalog, runtimeLock, bundledRuntimePath: cliScript });

        const voice = new VoiceService();
        const commands: string[] = [];
        voice.on('command', (cmd: string) => commands.push(cmd));
        await voice.initialize(undefined, {
            adapter,
            modelId: 'parakeet_unified_en',
            directory: tmpDir,
            vad: true,
            format: {
                vocabulary: [{ term: 'Quenderin', phoneticHints: ['quanderin'] }],
            },
        });
        expect(voice.hasNativeSpeech()).toBe(true);

        const transcription = await voice.transcribePcm(new Int16Array([0, 400, -400, 0]), 16000);
        expect(transcription?.text).toBe('check Quenderin release status');
        expect(commands).toEqual(['check Quenderin release status']);

        const loggedText = infoSpy.mock.calls.map(c => c.join(' ')).join('\n');
        expect(loggedText).not.toContain('Quenderin release status');
        expect(loggedText).toContain('Transcribed 30 chars');
        const lease = await nativeWorkloads.acquire('Idle Check');
        lease();
    });
});
