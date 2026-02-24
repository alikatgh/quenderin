import { EventEmitter } from 'events';
import { Porcupine, BuiltinKeyword } from '@picovoice/porcupine-node';
import { PvRecorder } from '@picovoice/pvrecorder-node';
import fs from 'fs';
import path from 'path';
import os from 'os';
import crypto from 'crypto';

export class VoiceService extends EventEmitter {
    private porcupine: Porcupine | null = null;
    private recorder: PvRecorder | null = null;
    private isListening = false;
    private STATE = 'IDLE'; // IDLE | RECORDING | TRANSCRIBING

    // We enforce exactly 10 seconds of speech
    private MAX_RECORDING_SAMPLES = 16000 * 10;
    private audioBuffer: Int16Array = new Int16Array(this.MAX_RECORDING_SAMPLES);
    private currentSampleIndex = 0;

    constructor() {
        super();
    }

    public async initialize(accessKey: string) {
        try {
            console.log('[VoiceService] Initializing Porcupine Wake Word Engine...');

            // Note: Porcupine requires a valid AccessKey from Picovoice Console
            if (!accessKey) {
                console.warn('[VoiceService] Missing PICOVOICE_ACCESS_KEY. Voice control disabled.');
                return;
            }

            this.porcupine = new Porcupine(
                accessKey,
                [BuiltinKeyword.PORCUPINE], // "Porcupine" is the default built-in wake word
                [0.5] // Sensitivity
            );

            const frameLength = this.porcupine.frameLength;
            this.recorder = new PvRecorder(-1, frameLength); // -1 is default mic
            console.log('[VoiceService] Audio pipeline ready. Say "Porcupine" to wake.');

            this.isListening = true;
            this.audioLoop(); // Start hardware polling asynchronously

        } catch (err: any) {
            console.error('[VoiceService] Failed to initialize:', err.message);
        }
    }

    private async audioLoop() {
        if (!this.recorder || !this.porcupine) return;

        try {
            this.recorder.start();
        } catch (e: any) {
            console.error('[VoiceService] Microphone access denied or in use:', e.message);
            return;
        }

        while (this.isListening) {
            // Non-blocking read array
            try {
                const pcm = await this.recorder.read();

                if (this.STATE === 'IDLE') {
                    // 1. Wake Word Detection Phase
                    const keywordIndex = this.porcupine.process(pcm);
                    if (keywordIndex === 0) {
                        console.log('\n[VoiceService] 🎙️  Wake word detected! Listening for 10 seconds...');
                        this.STATE = 'RECORDING';
                        this.currentSampleIndex = 0;
                        this.emit('wake');
                    }
                } else if (this.STATE === 'RECORDING') {
                    // 2. Audio Capture Phase
                    // Copy hardware frame into our 10-second buffer
                    if (this.currentSampleIndex + pcm.length < this.MAX_RECORDING_SAMPLES) {
                        this.audioBuffer.set(pcm, this.currentSampleIndex);
                        this.currentSampleIndex += pcm.length;
                    } else {
                        // Buffer full, end recording
                        console.log('[VoiceService] Recording finished. Transcribing offline...');
                        this.STATE = 'TRANSCRIBING';

                        // We must yield the main thread while we do heavy I/O and ML inference
                        setImmediate(() => this.processAudioBuffer());
                    }
                }
            } catch (err: any) {
                console.error('[VoiceService] Frame read error:', err.message);
            }
        }
    }

    private async processAudioBuffer() {
        try {
            // Trim actual recorded length if it ended early (though currently we force 10s)
            const recordedFrames = this.audioBuffer.slice(0, this.currentSampleIndex);

            // whisper-node requires a physical .wav file on disk. 
            // We must manually encode the PCM Int16 raw frames to standard WAV.
            const wavPath = path.join(os.tmpdir(), `quenderin_voice_${crypto.randomUUID()}.wav`);
            this.writeWavFile(wavPath, recordedFrames, 16000, 1);

            // 3. Offline Transcription Phase
            // Setup dynamic whisper import just like the old mock did to save memory until invoked
            const whisperModule = await import('whisper-node');
            const whisper = whisperModule.default || whisperModule.whisper;

            const options = {
                modelName: "tiny.en", // Using the smallest, fastest English-only model
                whisperOptions: { word_timestamps: false }
            };

            const transcripts = await whisper(wavPath, options);

            // Clean up the temporary file
            fs.unlinkSync(wavPath);

            // whisper-node returns an array of objects: {start, end, speech}
            let fullText = "";
            for (const t of transcripts) {
                fullText += " " + t.speech;
            }
            const cleanText = fullText.trim();

            if (cleanText.length > 0) {
                console.log(`[VoiceService] Transcription: "${cleanText}"`);
                this.emit('command', cleanText); // Pipe to AgentService!
            } else {
                console.log('[VoiceService] No speech detected.');
            }

        } catch (err: any) {
            console.error('[VoiceService] Transcription Error:', err.message);
        } finally {
            // Return to IDLE 
            this.STATE = 'IDLE';
            console.log('[VoiceService] Returning to sleep state. Say "Porcupine" to wake.');
        }
    }

    /**
     * Helper to encode raw PCM 16-bit 16kHz audio array into a standard .wav file
     */
    private writeWavFile(filepath: string, pcmBuffer: Int16Array, sampleRate: number, numChannels: number) {
        const byteRate = sampleRate * numChannels * 2;
        const blockAlign = numChannels * 2;
        const dataSize = pcmBuffer.length * 2;
        const buffer = Buffer.alloc(44 + dataSize);

        // RIFF chunk descriptor
        buffer.write('RIFF', 0);
        buffer.writeUInt32LE(36 + dataSize, 4);
        buffer.write('WAVE', 8);

        // FMT sub-chunk
        buffer.write('fmt ', 12);
        buffer.writeUInt32LE(16, 16); // Subchunk1Size (16 for PCM)
        buffer.writeUInt16LE(1, 20); // AudioFormat (1 = PCM)
        buffer.writeUInt16LE(numChannels, 22);
        buffer.writeUInt32LE(sampleRate, 24);
        buffer.writeUInt32LE(byteRate, 28);
        buffer.writeUInt16LE(blockAlign, 32);
        buffer.writeUInt16LE(16, 34); // BitsPerSample

        // Data sub-chunk
        buffer.write('data', 36);
        buffer.writeUInt32LE(dataSize, 40);

        // Write PCM data
        let offset = 44;
        for (let i = 0; i < pcmBuffer.length; i++) {
            buffer.writeInt16LE(pcmBuffer[i], offset);
            offset += 2;
        }

        fs.writeFileSync(filepath, buffer);
    }

    public shutdown() {
        this.isListening = false;
        if (this.recorder) {
            this.recorder.stop();
            this.recorder.release();
        }
        if (this.porcupine) this.porcupine.release();
        console.log('[VoiceService] Hardware released.');
    }
}
