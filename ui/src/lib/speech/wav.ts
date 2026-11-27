/** Browser-side audio → WAV encoder for local transcription. */

export const SPEECH_SAMPLE_RATE_HZ = 16000 as const;
/** Matches shared/speech-runtime.json bounds.maxAudioBytes (64 MiB). */
export const SPEECH_MAX_AUDIO_BYTES = 64 * 1024 * 1024;

export interface EncodedWav {
    readonly blob: Blob;
    readonly bytes: number;
    readonly durationMs: number;
    readonly sampleRate: number;
    readonly channels: 1;
}

/** Encode mono Float32 samples in [-1, 1] as a 16-bit PCM WAV. */
export function encodePcm16Wav(_samples: Float32Array, _sampleRate?: number): Blob {
    throw new Error('TODO(stage2): write a 44-byte RIFF header + clamped int16 LE samples.');
}

/** Linear resample to 16 kHz (mic devices usually run at 44.1/48 kHz). */
export function downsampleTo16k(_samples: Float32Array, _inputSampleRate: number): Float32Array {
    throw new Error('TODO(stage2): resample mono Float32 audio to 16 kHz.');
}

/** Convert an AudioBuffer (from MediaRecorder/WebAudio) to the backend contract. */
export function audioBufferToWav16k(_buffer: AudioBuffer): EncodedWav {
    throw new Error('TODO(stage2): mix to mono, resample and encode.');
}

/** Decode any recorded Blob and return a 16 kHz mono WAV. */
export async function blobToWav16k(_blob: Blob): Promise<EncodedWav> {
    throw new Error('TODO(stage2): decode via AudioContext, mix to mono, resample and encode.');
}

/** Guard used before POSTing so oversized recordings fail in the composer, not the server. */
export function assertWavWithinLimit(_wav: EncodedWav): void {
    throw new Error('TODO(stage2): reject WAVs above SPEECH_MAX_AUDIO_BYTES with a readable message.');
}
