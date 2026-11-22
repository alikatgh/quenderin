import { EventEmitter } from 'events';
import fs from 'fs';
import path from 'path';
import os from 'os';
import crypto from 'crypto';
import logger from '../utils/logger.js';
import {
    HexSpeechAdapter,
    type DictationFormatOptions,
    type SpeechTranscriptionResult,
} from './hexSpeechAdapter.js';

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

type VoiceState = 'IDLE' | 'RECORDING' | 'TRANSCRIBING';

export interface VoiceSpeechConfig {
    modelId: string;
    directory?: string;
    runtime?: string;
    vad?: boolean;
    language?: string;
    prompt?: string;
    threads?: number;
    hexUrl?: string;
    hexToken?: string;
    hexDiscoveryPath?: string;
    hexExecutable?: string;
    format?: DictationFormatOptions;
}

export class VoiceService extends EventEmitter {
    private porcupine: PorcupineLike | null = null;
    private recorder: PvRecorderLike | null = null;
    private isListening = false;
    private STATE: VoiceState = 'IDLE'; // IDLE | RECORDING | TRANSCRIBING
    private voiceAvailable = false;
    private speechAdapter: HexSpeechAdapter | null = null;
    private speechConfig: VoiceSpeechConfig | null = null;

    // We enforce exactly 10 seconds of speech
    private MAX_RECORDING_SAMPLES = 16000 * 10;
    private audioBuffer: Int16Array = new Int16Array(this.MAX_RECORDING_SAMPLES);
    private currentSampleIndex = 0;

    constructor() {
        super();
    }

    public configureSpeech(adapter: HexSpeechAdapter, config: VoiceSpeechConfig): void {
        adapter.model(config.modelId);
        this.speechAdapter = adapter;
        this.speechConfig = { ...config };
        this.voiceAvailable = true;
        logger.info(`[Voice] Native Hex speech backend configured (model=${config.modelId}).`);
    }

    public hasNativeSpeech(): boolean {
        return Boolean(this.speechAdapter && this.speechConfig);
    }

    public async initialize(accessKey?: string, speechConfig?: { adapter?: HexSpeechAdapter } & VoiceSpeechConfig) {
        try {
            logger.info('[Voice] Initializing voice helper...');

            if (speechConfig) {
                const adapter = speechConfig.adapter ?? new HexSpeechAdapter();
                this.configureSpeech(adapter, speechConfig);
            }

            // Note: Porcupine requires a valid AccessKey from Picovoice Console
            if (!accessKey) {
                if (!this.hasNativeSpeech()) {
                    this.emit('action_required', {
                        code: 'PICOVOICE_MISSING',
                        title: 'Voice Engine Unconfigured',
                        message: 'Provide a Picovoice Access Key or configure QUENDERIN_SPEECH_MODEL for offline voice commands.'
                    });
                    logger.warn('[Voice] No wake-word key or native speech model configured — voice disabled.');
                } else {
                    logger.info('[Voice] Ready in headless/manual Hex transcription mode (no wake-word key set).');
                }
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
                logger.info('[Voice] Picovoice native modules not available — wake-word detection disabled.');
                return;
            }

            this.porcupine = new Porcupine(
                accessKey,
                [BuiltinKeyword.JARVIS], // Changing to "Jarvis" for a more "Unified Intelligence" feel
                [0.5] // Sensitivity
            );

            const frameLength = this.porcupine!.frameLength;
            this.recorder = new PvRecorder(-1, frameLength); // -1 is default mic
            logger.info('[Voice] Ready. Say "Jarvis" or use the Record button.');

            this.voiceAvailable = true;
            this.isListening = true;
            this.audioLoop(); // Start hardware polling asynchronously

        } catch (err: unknown) {
            logger.error('[Voice] Failed to initialize:', err);
        }
    }

    private async audioLoop() {
        if (!this.recorder || !this.porcupine) return;

        try {
            this.recorder.start();
        } catch (e: unknown) {
            logger.error('[Voice] Microphone access denied or hardware locked:', e);
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
                        logger.info('[Voice] Wake word detected — listening...');
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
                        logger.debug('[Voice] Buffer full — transcribing...');
                        this.STATE = 'TRANSCRIBING';

                        // We must yield the main thread while we do heavy I/O and ML inference
                        setImmediate(() => this.processAudioBuffer());
                    }
                }
            } catch (err: unknown) {
                logger.error('[Voice] Frame read error:', err);
            }
        }
    }

    public async manualCaptureStart() {
        // Without a loaded recorder, audioLoop never runs, so STATE stays IDLE and we would
        // otherwise flip to RECORDING and later transcribe an empty buffer.
        if (!this.voiceAvailable || !this.recorder) return;
        if (this.STATE !== 'IDLE') return;
        logger.info('[Voice] Manual recording started.');
        this.STATE = 'RECORDING';
        this.currentSampleIndex = 0;
        this.emit('wake');
    }

    public async manualCaptureStop() {
        if (!this.voiceAvailable || !this.recorder) return;
        if (this.STATE !== 'RECORDING') return;
        logger.debug('[Voice] Processing manual recording...');
        this.STATE = 'TRANSCRIBING';
        setImmediate(() => this.processAudioBuffer());
    }

    private async processAudioBuffer() {
        // Hoisted so the `finally` can always remove the temp WAV — previously a throw from
        // whisper() skipped the success-path unlink and leaked the file (audit re-sweep, voice).
        let wavPath: string | null = null;
        try {
            // Trim actual recorded length if it ended early (though currently we force 10s)
            const recordedFrames = this.audioBuffer.slice(0, this.currentSampleIndex);

            // whisper-node requires a physical .wav file on disk.
            // We must manually encode the PCM Int16 raw frames to standard WAV.
            wavPath = path.join(os.tmpdir(), `quenderin_voice_${crypto.randomUUID()}.wav`);
            this.writeWavFile(wavPath, recordedFrames, 16000, 1);

            await this.transcribeWav(wavPath);

        } catch (err: unknown) {
            logger.error('[Voice] Transcription error:', err);
        } finally {
            // Always remove the temp WAV — even on the whisper-throw path that previously leaked it.
            if (wavPath) {
                await fs.promises.unlink(wavPath).catch(() => { /* already removed or never written */ });
            }
            // Return to IDLE
            this.STATE = 'IDLE';
            logger.debug('[Voice] Returning to idle state.');
        }
    }

    public async transcribePcm(pcmBuffer: Int16Array, sampleRate = 16000, signal?: AbortSignal): Promise<SpeechTranscriptionResult | null> {
        if (sampleRate !== 16000) {
            throw new Error('PCM voice transcription requires 16000 Hz mono audio.');
        }
        const wavPath = path.join(os.tmpdir(), `quenderin_voice_${crypto.randomUUID()}.wav`);
        try {
            this.writeWavFile(wavPath, pcmBuffer, sampleRate, 1);
            return await this.transcribeWav(wavPath, signal);
        } finally {
            await fs.promises.unlink(wavPath).catch(() => { /* already removed */ });
        }
    }

    public async transcribeWav(wavPath: string, signal?: AbortSignal): Promise<SpeechTranscriptionResult | null> {
        let result: SpeechTranscriptionResult | null = null;
        if (this.speechAdapter && this.speechConfig) {
            const cfg = this.speechConfig;
            if (cfg.hexUrl || cfg.hexDiscoveryPath || cfg.hexExecutable) {
                result = await this.speechAdapter.transcribeWithHexHost({
                    model: cfg.modelId,
                    wav: wavPath,
                    hexUrl: cfg.hexUrl,
                    hexToken: cfg.hexToken,
                    hexDiscoveryPath: cfg.hexDiscoveryPath,
                    hexExecutable: cfg.hexExecutable,
                    language: cfg.language,
                    format: cfg.format,
                    signal,
                });
            } else if (cfg.directory) {
                result = await this.speechAdapter.transcribeWithCli({
                    model: cfg.modelId,
                    directory: cfg.directory,
                    wav: wavPath,
                    vad: cfg.vad,
                    runtime: cfg.runtime,
                    language: cfg.language,
                    prompt: cfg.prompt,
                    threads: cfg.threads,
                    format: cfg.format,
                    signal,
                });
            } else {
                throw new Error('Speech backend is missing a model directory or Hex loopback host configuration.');
            }
        } else {
            // 3. Optional whisper-node fallback
            let whisper: any;
            try {
                const whisperModule = await import('whisper-node');
                whisper = whisperModule.default || whisperModule.whisper;
            } catch {
                logger.info('[Voice] Neither Hex native speech nor whisper-node available — speech-to-text disabled.');
                return null;
            }

            const options = {
                modelName: "tiny.en",
                whisperOptions: { word_timestamps: false }
            };
            const transcripts = await whisper(wavPath, options);
            let fullText = '';
            for (const t of transcripts) {
                fullText += ' ' + t.speech;
            }
            const clean = fullText.trim();
            result = {
                text: clean,
                rawText: clean,
                language: 'en',
                backend: 'whisper-node',
                modelId: 'tiny.en',
                durationMs: 0,
                truncated: false,
                segments: [],
            };
        }

        const cleanText = result.text.trim();
        if (cleanText.length > 0) {
            // Privacy: the transcript IS the user's private speech — never write the content to
            // logs (audit re-sweep, PII). Length only; the command itself goes only to the agent.
            logger.info(`[Voice] Transcribed ${cleanText.length} chars — emitting command.`);
            this.emit('command', cleanText);
        } else {
            logger.debug('[Voice] Empty transcription — no command emitted.');
        }
        return result;
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
            logger.info('[VoiceService] Hardware released.');
        }
    }
}
