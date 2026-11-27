import { describe, it } from 'vitest';

/**
 * Stage 2 wires src/services/speech/transcribe.ts to the existing
 * HexSpeechAdapter. Tests use synthetic 16 kHz WAV fixtures and a fake
 * adapter; never real model weights and never a microphone.
 */
describe('local speech transcription', () => {
    it.todo('accepts 16 kHz mono 16-bit PCM WAV and returns text + segments');
    it.todo('rejects mono at 44.1 kHz, stereo, 8-bit and non-RIFF audio');
    it.todo('rejects an empty or truncated WAV with a readable error');
    it.todo('enforces the 64 MiB cap before spawning the runtime');
    it.todo('returns 409-style unsupported-engine for minEngine > pinned runtime');
    it.todo('passes the model id and language hint to HexSpeechAdapter.transcribe');
    it.todo('maps rawText, formatted text, language, backend, durationMs and truncated');
    it.todo('propagates cancellation through AbortSignal without logging the transcript');
});
