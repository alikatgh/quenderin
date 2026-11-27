import type {
    DictationFormatOptions,
    HexSpeechAdapter,
} from '../hexSpeechAdapter.js';
import type {
    HandySpeechCatalog,
    HandySpeechModel,
} from './types.js';
import type {
    SpeechTranscriptionRequest,
    SpeechTranscriptionResponse,
} from './types.js';

export interface TranscribeSpeechOptions {
    readonly catalog: HandySpeechCatalog;
    /** Pinned transcribe.cpp version from shared/speech-runtime.json. */
    readonly pinnedEngineVersion: string;
    /** Reuse the existing native adapter; do not construct a second one per request. */
    readonly adapter: HexSpeechAdapter;
    readonly format?: DictationFormatOptions;
    readonly signal?: AbortSignal;
}

/**
 * Turn a captured WAV into text fully locally: validate the 16 kHz mono PCM
 * contract, gate on the pinned engine, then hand the bytes to the existing
 * HexSpeechAdapter/transcribe.cpp runtime. No cloud call is made.
 */
export async function transcribeSpeech(
    _options: TranscribeSpeechOptions,
    _request: SpeechTranscriptionRequest,
): Promise<SpeechTranscriptionResponse> {
    throw new Error('TODO(stage2): validate WAV, verify model/engine, call HexSpeechAdapter and map the result.');
}

/** Reject unknown models and models whose minEngine is newer than the runtime. */
export function assertModelTranscribable(
    _catalog: HandySpeechCatalog,
    _modelId: string,
    _pinnedEngineVersion: string,
): HandySpeechModel {
    throw new Error('TODO(stage2): resolve the model and gate on minEngine <= pinned runtime.');
}

/** Enforce the WAV size cap before buffering the request body. */
export function validateTranscriptionAudio(_wav: Buffer, _maxBytes: number): void {
    throw new Error('TODO(stage2): enforce the size cap and the 16 kHz mono 16-bit PCM WAV contract.');
}

/** Map the adapter's SpeechTranscriptionResult onto the REST response body. */
export function toTranscriptionResponse(
    _result: Awaited<ReturnType<HexSpeechAdapter['transcribe']>>,
    _autoSend: boolean,
): SpeechTranscriptionResponse {
    throw new Error('TODO(stage2): map rawText/text/language/backend/durationMs/segments.');
}
