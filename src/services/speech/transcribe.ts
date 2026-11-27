import { type DictationFormatOptions, type HexSpeechAdapter, validateWavBuffer } from '../hexSpeechAdapter.js';
import { findCatalogModel } from './catalog.js';
import { SpeechError } from './errors.js';
import { engineCompatibility } from './grading.js';
import type {
    HandySpeechCatalog, HandySpeechModel, SpeechTranscriptionRequest, SpeechTranscriptionResponse,
} from './types.js';

export interface TranscribeSpeechOptions {
    readonly catalog: HandySpeechCatalog;
    readonly pinnedEngineVersion: string;
    readonly modelsDir: string;
    readonly maxAudioBytes: number;
    readonly adapter: Pick<HexSpeechAdapter, 'transcribe'>;
    readonly format?: DictationFormatOptions;
    readonly signal?: AbortSignal;
}

export async function transcribeSpeech(
    options: TranscribeSpeechOptions,
    request: SpeechTranscriptionRequest,
): Promise<SpeechTranscriptionResponse> {
    validateTranscriptionAudio(request.wav, options.maxAudioBytes);
    const model = assertModelTranscribable(options.catalog, request.modelId, options.pinnedEngineVersion);
    try {
        const result = await options.adapter.transcribe({
            model: model.id, directory: options.modelsDir, wav: request.wav,
            signal: options.signal, format: options.format, language: request.language,
            timestamps: model.capabilities.timestamps,
        });
        return { ...result, autoSend: request.autoSend ?? false };
    } catch (error) {
        if (options.signal?.aborted) throw new SpeechError('cancelled', 409, 'Transcription was cancelled.');
        const message = error instanceof Error ? error.message : '';
        if (/already running|current text operation|using the local engine/i.test(message)) {
            throw new SpeechError('speech-busy', 409, 'Finish the current local model operation before dictating again.');
        }
        if (/runtime.*(?:unavailable|identity|ABI)|regular executable/i.test(message)
            || (error as NodeJS.ErrnoException | undefined)?.code === 'EACCES') {
            throw new SpeechError('runtime-unavailable', 503, 'The pinned local speech runtime is unavailable. Install a Quenderin build with the speech runtime.');
        }
        throw new SpeechError('transcription-failed', 502, 'The local speech engine could not transcribe the recording. Try recording again or choose a different voice model.');
    }
}

export function assertModelTranscribable(catalog: HandySpeechCatalog, modelId: string, pinnedEngineVersion: string): HandySpeechModel {
    const model = findCatalogModel(catalog, modelId);
    if (!model) throw new SpeechError('unknown-model', 404, 'Unknown speech model.');
    if (engineCompatibility(model.minEngine, pinnedEngineVersion) !== 'supported') {
        throw new SpeechError('unsupported-engine', 409, `Needs newer speech engine (${model.minEngine}).`);
    }
    return model;
}

export function validateTranscriptionAudio(wav: Buffer, maxBytes: number): void {
    if (wav.length > maxBytes) throw new SpeechError('audio-too-large', 413, 'The recording is too large.');
    try {
        validateWavBuffer(wav);
        if (wav.readUInt32LE(4) !== wav.length - 8) throw new Error('RIFF size mismatch.');
    } catch {
        throw new SpeechError('invalid-audio', 415, 'Audio must be non-empty 16 kHz mono 16-bit PCM WAV.');
    }
}
