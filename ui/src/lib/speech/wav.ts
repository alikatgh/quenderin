// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Downmix adapted from Handy src-tauri/src/audio_toolkit/audio/decode.rs
// at 05efc5fc180197dc0fa9d568dd9812904b723b8b. See THIRD_PARTY_NOTICES.md.

export const SPEECH_SAMPLE_RATE_HZ = 16000;
export const SPEECH_MAX_AUDIO_BYTES = 64 * 1024 * 1024;

export function audioBufferToWav16k(audio: AudioBuffer): Blob {
    const size = 44 + audio.length * 2;
    if (size > SPEECH_MAX_AUDIO_BYTES) throw new Error('The recording is too large. Try a shorter recording.');
    if (!audio.length || !audio.numberOfChannels || audio.sampleRate !== SPEECH_SAMPLE_RATE_HZ) {
        throw new Error('Could not convert the recording to 16 kHz speech audio.');
    }
    const buffer = new ArrayBuffer(size);
    const view = new DataView(buffer);
    const ascii = (offset: number, value: string) => {
        for (let i = 0; i < value.length; i++) view.setUint8(offset + i, value.charCodeAt(i));
    };
    ascii(0, 'RIFF');
    view.setUint32(4, size - 8, true);
    ascii(8, 'WAVEfmt ');
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 1, true);
    view.setUint32(24, SPEECH_SAMPLE_RATE_HZ, true);
    view.setUint32(28, SPEECH_SAMPLE_RATE_HZ * 2, true);
    view.setUint16(32, 2, true);
    view.setUint16(34, 16, true);
    ascii(36, 'data');
    view.setUint32(40, size - 44, true);

    const channels = Array.from({ length: audio.numberOfChannels }, (_, i) => audio.getChannelData(i));
    for (let frame = 0; frame < audio.length; frame++) {
        let sum = 0;
        for (const channel of channels) sum += channel[frame];
        const sample = Math.max(-1, Math.min(1, sum / channels.length));
        view.setInt16(44 + frame * 2, Math.round(sample * (sample < 0 ? 32768 : 32767)), true);
    }
    return new Blob([buffer], { type: 'audio/wav' });
}

export async function blobToWav16k(recording: Blob): Promise<Blob> {
    if (!recording.size) throw new Error('No audio was captured. Hold the microphone button while speaking.');
    // Web Audio decodes and resamples the recorder's native format using its audio resampler.
    const context = new AudioContext({ sampleRate: SPEECH_SAMPLE_RATE_HZ });
    try {
        return audioBufferToWav16k(await context.decodeAudioData(await recording.arrayBuffer()));
    } finally {
        await context.close();
    }
}
