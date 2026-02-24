import { Porcupine, BuiltinKeyword } from '@picovoice/porcupine-node';
import { whisper } from 'whisper-node';
import { EventEmitter } from 'events';
import fs from 'fs';
import path from 'path';
import os from 'os';

export class VoiceService extends EventEmitter {
    private porcupine: Porcupine | null = null;
    private isListening = false;
    private modelPath: string;

    constructor(private picovoiceApiKey: string) {
        super();
        this.modelPath = path.join(os.homedir(), '.quenderin', 'models', 'ggml-base.en.bin');

        // Auto-create model dir if missing
        const modelDir = path.dirname(this.modelPath);
        if (!fs.existsSync(modelDir)) {
            fs.mkdirSync(modelDir, { recursive: true });
        }
    }

    public async initialize() {
        try {
            // Initialize Wake Word Engine
            if (!this.picovoiceApiKey || this.picovoiceApiKey === 'DEMO_KEY') {
                this.emit('status', 'Warning: No Picovoice API Key provided. Voice wake word is disabled.');
                return;
            }

            this.porcupine = new Porcupine(
                this.picovoiceApiKey,
                [BuiltinKeyword.COMPUTER],
                [0.5] // Sensitivity
            );

            // Wait until Whisper base model exists. Production app would auto-download it via fetch() here.
            if (!fs.existsSync(this.modelPath)) {
                this.emit('error', `Whisper model not found at ${this.modelPath}. Please download ggml-base.en.bin.`);
            } else {
                this.emit('status', 'Voice Service initialized. Waiting for wake word "Computer".');
            }

        } catch (error: any) {
            this.emit('error', `Failed to initialize VoiceService: ${error.message}`);
        }
    }

    // Connects to a raw audio stream (e.g. from node-record-lpcm16 or an Electron MediaStream)
    public processAudioFrame(frame: Int16Array) {
        if (!this.porcupine || this.isListening) return;

        try {
            const keywordIndex = this.porcupine.process(frame);
            if (keywordIndex === 0) {
                this.emit('status', 'Wake word "Computer" detected! Waiting for command...');
                this.emit('wake');
                this.startRecordingCommand();
            }
        } catch (error: any) {
            this.emit('error', `Wake word processing error: ${error.message}`);
        }
    }

    private async startRecordingCommand() {
        this.isListening = true;
        // In a real implementation, this would buffer the next 5-10 seconds of mic input to a temp.wav file
        const tempWavPath = path.join(os.tmpdir(), `quenderin-cmd-${Date.now()}.wav`);

        this.emit('status', 'Recording audio command... (simulated)');

        // ... simulated recording delay ...
        await new Promise(res => setTimeout(res, 3000));

        // Pretend we wrote the buffer out to wav
        if (fs.existsSync(tempWavPath)) {
            try {
                this.emit('status', 'Transcribing audio via local Whisper model...');
                const transcriptOptions = {
                    modelName: this.modelPath,
                    language: "en"
                };

                const transcripts = await whisper(tempWavPath, transcriptOptions);
                const finalCommand = transcripts.map(t => t.speech).join(" ").trim();

                if (finalCommand) {
                    this.emit('command', finalCommand);
                }
            } catch (err: any) {
                this.emit('error', `Failed to transcribe: ${err.message}`);
            } finally {
                fs.unlinkSync(tempWavPath);
            }
        }

        this.isListening = false;
    }
}
