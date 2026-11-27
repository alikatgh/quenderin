import { catalog } from '@handy-computer/models';
import { describe, expect, it, vi } from 'vitest';
import { SPEECH_MAX_AUDIO_BYTES, validateWavBuffer, type HexSpeechAdapter } from '../src/services/hexSpeechAdapter.js';
import { transcribeSpeech, validateTranscriptionAudio } from '../src/services/speech/transcribe.js';
import { fixtureModel, wavFixture } from './helpers/speechFixtures.js';

const model = fixtureModel();
const result = {
    text: 'Good morning.', rawText: ' good morning ', language: 'en',
    backend: 'transcribe.cpp', modelId: model.id, durationMs: 15, truncated: false,
    segments: [{ startMs: 0, endMs: 15, text: 'Good morning.' }],
};

function setup() {
    const transcribe = vi.fn<HexSpeechAdapter['transcribe']>().mockResolvedValue(result);
    return {
        catalog, pinnedEngineVersion: '0.4.1', modelsDir: '/fixture/speech', maxAudioBytes: SPEECH_MAX_AUDIO_BYTES,
        adapter: { transcribe },
    };
}

describe('local transcription', () => {
    it('passes the WAV bytes and native options through the local adapter', async () => {
        const options = setup();
        const wav = wavFixture();
        const signal = new AbortController().signal;
        await expect(transcribeSpeech({ ...options, signal }, { wav, modelId: model.id, language: 'en', autoSend: true }))
            .resolves.toEqual({ ...result, autoSend: true });
        expect(options.adapter.transcribe).toHaveBeenCalledWith(expect.objectContaining({
            model: model.id, wav, language: 'en', directory: options.modelsDir, signal,
        }));
    });

    it.each([
        ['PCM format', (wav: Buffer) => wav.writeUInt16LE(3, 20)],
        ['stereo channels', (wav: Buffer) => wav.writeUInt16LE(2, 22)],
        ['44.1 kHz sample rate', (wav: Buffer) => wav.writeUInt32LE(44_100, 24)],
        ['invalid byte rate', (wav: Buffer) => wav.writeUInt32LE(64_000, 28)],
        ['invalid block alignment', (wav: Buffer) => wav.writeUInt16LE(4, 32)],
        ['8-bit depth', (wav: Buffer) => wav.writeUInt16LE(8, 34)],
        ['truncated data', (wav: Buffer) => wav.writeUInt32LE(1000, 40)],
        ['empty data', (wav: Buffer) => wav.writeUInt32LE(0, 40)],
        ['odd PCM length', (wav: Buffer) => wav.writeUInt32LE(5, 40)],
        ['RIFF length mismatch', (wav: Buffer) => wav.writeUInt32LE(80, 4)],
        ['non-RIFF input', (wav: Buffer) => wav.write('AAAA', 0)],
    ] as const)('rejects %s before invoking the adapter', async (_, modify) => {
        const options = setup();
        const wav = wavFixture();
        modify(wav);
        await expect(transcribeSpeech(options, { wav, modelId: model.id }))
            .rejects.toMatchObject({ status: 415, code: 'invalid-audio' });
        expect(options.adapter.transcribe).not.toHaveBeenCalled();
    });

    it('enforces the request size bound without allocating a 64 MiB fixture', () => {
        const wav = wavFixture();
        expect(() => validateTranscriptionAudio(wav, wav.length - 1)).toThrow(expect.objectContaining({ status: 413 }));
    });

    it('rejects string and array parameter-tampering payloads before reading buffer bytes', () => {
        for (const tampered of ['RIFFfake', ['RIFF', 'WAVE'], { length: 100 }]) {
            expect(() => validateWavBuffer(tampered as unknown as Buffer)).toThrow(/RIFF WAVE buffer/);
            expect(() => validateTranscriptionAudio(tampered as unknown as Buffer, 1024))
                .toThrow(expect.objectContaining({ status: 415, code: 'invalid-audio' }));
        }
    });

    it('rejects unsupported engines before invoking the adapter', async () => {
        const options = setup();
        await expect(transcribeSpeech({ ...options, pinnedEngineVersion: '0.0.1' }, { wav: wavFixture(), modelId: model.id }))
            .rejects.toMatchObject({ status: 409, code: 'unsupported-engine' });
        expect(options.adapter.transcribe).not.toHaveBeenCalled();
    });

    it('returns a runtime availability error without exposing adapter internals', async () => {
        const options = setup();
        options.adapter.transcribe.mockRejectedValue(new Error('The pinned speech runtime is unavailable. /some/private/path'));
        await expect(transcribeSpeech(options, { wav: wavFixture(), modelId: model.id }))
            .rejects.toMatchObject({ status: 503, code: 'runtime-unavailable' });
    });

    it('propagates the abort signal and reports a cancelled local operation', async () => {
        const options = setup();
        const controller = new AbortController();
        options.adapter.transcribe.mockImplementationOnce(request => {
            expect(request.signal).toBe(controller.signal);
            controller.abort();
            throw Error('Runtime aborted');
        });
        await expect(transcribeSpeech({ ...options, signal: controller.signal }, { wav: wavFixture(), modelId: model.id }))
            .rejects.toMatchObject({ status: 409, code: 'cancelled' });
    });
});
