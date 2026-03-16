import { EventEmitter } from 'events';
import fs from 'fs';
import path from 'path';
import os from 'os';
import crypto from 'crypto';

// Picovoice types — loaded dynamically since they are optional native deps
interface PorcupineLike {
    frameLength: number;
    process(pcm: Int16Array): number;
    release(): void;
}
interface PvRecorderLike {
    start(): void;
    stop(): void;
    read(): Promise<Int16Array>;
    release(): void;
}

export class VoiceService extends EventEmitter {
    private porcupine: PorcupineLike | null = null;
    private recorder: PvRecorderLike | null = null;
    private isListening = false;
    private STATE = 'IDLE'; // IDLE | RECORDING | TRANSCRIBING
    private voiceAvailable = false;

    // We enforce exactly 10 seconds of speech
    private MAX_RECORDING_SAMPLES = 16000 * 10;
    private audioBuffer: Int16Array = new Int16Array(this.MAX_RECORDING_SAMPLES);
    private currentSampleIndex = 0;

    constructor() {
        super();
    }

    public async initialize(accessKey: string) {
        try {
            console.log('[Assistant] Prepping voice helper...');

            // Note: Porcupine requires a valid AccessKey from Picovoice Console
            if (!accessKey) {
                this.emit('action_required', {
                    code: 'PICOVOICE_MISSING',
                    title: 'Voice Engine Unconfigured',
                    message: 'Please provide a valid Picovoice Access Key to enable offline voice commands.'
                });
                console.warn('[Assistant] Voice Helper is sleeping (Missing Key).');
                return;
            }

            // Dynamically import optional native modules — they may not be installed
            // on all platforms (e.g. ARM SBCs, musl-based distros, Windows ARM64)
            let Porcupine: any, BuiltinKeyword: any, PvRecorder: any;
            try {
                const porcupineMod = await import('@picovoice/porcupine-node');
                Porcupine = porcupineMod.Porcupine;
                BuiltinKeyword = porcupineMod.BuiltinKeyword;
                const recorderMod = await import('@picovoice/pvrecorder-node');
                PvRecorder = recorderMod.PvRecorder;
            } catch {
                console.warn(
                    '[VoiceService] Picovoice native modules not available on this platform. ' +
                    'Voice wake-word detection is disabled. ' +
                    'Manual recording via the UI button still works if whisper-node is installed.'
                );
                return;
            }

            this.porcupine = new Porcupine(
                accessKey,
                [BuiltinKeyword.JARVIS], // Changing to "Jarvis" for a more "Unified Intelligence" feel
                [0.5] // Sensitivity
            );

            const frameLength = this.porcupine!.frameLength;
            this.recorder = new PvRecorder(-1, frameLength); // -1 is default mic
            console.log('[Assistant] Ready to help. Say "Jarvis" or use the Record button.');

            this.voiceAvailable = true;
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
            console.error('[VoiceService] Microphone access denied or hardware locked:', e.message);
            this.emit('action_required', {
                code: 'MIC_ACCESS_DENIED',
                title: 'Microphone Unavailable',
                message: 'Quenderin requires microphone access to hear wake words. Ensure no other application is locking the mic and your OS permissions allow access.'
            });
            this.shutdown();
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
                        console.log('\n[Assistant] 🎙️ I\'m listening...');
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
                        console.log('[Assistant] Thinking about what you said...');
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

    public async manualCaptureStart() {
        if (this.STATE !== 'IDLE') return;
        console.log('[Assistant] 🎙️ Manual recording started...');
        this.STATE = 'RECORDING';
        this.currentSampleIndex = 0;
        this.emit('wake');
    }

    public async manualCaptureStop() {
        if (this.STATE !== 'RECORDING') return;
        console.log('[Assistant] Processing manual recording...');
        this.STATE = 'TRANSCRIBING';
        setImmediate(() => this.processAudioBuffer());
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
            // whisper-node is an optional native dep — may not compile on all platforms
            let whisper: any;
            try {
                const whisperModule = await import('whisper-node');
                whisper = whisperModule.default || whisperModule.whisper;
            } catch {
                console.warn(
                    '[VoiceService] whisper-node is not available on this platform. ' +
                    'Speech-to-text is disabled. Install it with "npm install whisper-node" if your platform supports it.'
                );
                await fs.promises.unlink(wavPath).catch(() => {});
                return;
            }

            const options = {
                modelName: "tiny.en", // Using the smallest, fastest English-only model
                whisperOptions: { word_timestamps: false }
            };

            const transcripts = await whisper(wavPath, options);

            // Clean up the temporary file
            await fs.promises.unlink(wavPath);

            // whisper-node returns an array of objects: {start, end, speech}
            let fullText = "";
            for (const t of transcripts) {
                fullText += " " + t.speech;
            }
            const cleanText = fullText.trim();

            if (cleanText.length > 0) {
                console.log(`[Assistant] I heard: "${cleanText}"`);
                this.emit('command', cleanText); // Pipe to AgentService!
            } else {
                console.log('[Assistant] I didn\'t catch that.');
            }

        } catch (err: any) {
            console.error('[VoiceService] Transcription Error:', err.message);
        } finally {
            // Return to IDLE
            this.STATE = 'IDLE';
            console.log('[Assistant] Going back to sleep. Say "Jarvis" if you need anything.');
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
        try {
            if (this.recorder) {
                this.recorder.stop();
                this.recorder.release();
            }
        } catch { /* recorder may already be released or never started */ }
        try {
            if (this.porcupine) this.porcupine.release();
        } catch { /* best-effort cleanup */ }
        if (this.voiceAvailable) {
            console.log('[VoiceService] Hardware released.');
        }
    }
}
