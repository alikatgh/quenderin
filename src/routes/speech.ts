import type { Router } from 'express';
import type { HandySpeechCatalog } from '../services/speech/types.js';
import type { SpeechDownloadManager } from '../services/speech/downloadManager.js';
import type { SpeechSettingsStore } from '../services/speech/speechSettings.js';
import type {
    SpeechModelListResponse,
    SpeechTranscriptionRequest,
    SpeechTranscriptionResponse,
} from '../services/speech/types.js';

/** The REST surface. `GET /api/speech/downloads` is served by the WS event stream too. */
export const SPEECH_ROUTES = {
    models: 'GET /api/speech/models',
    downloads: 'POST /api/speech/downloads',
    downloadStatus: 'GET /api/speech/downloads/:modelId',
    pause: 'POST /api/speech/downloads/:modelId/pause',
    resume: 'POST /api/speech/downloads/:modelId/resume',
    cancel: 'POST /api/speech/downloads/:modelId/cancel',
    retry: 'POST /api/speech/downloads/:modelId/retry',
    transcribe: 'POST /api/speech/transcribe',
    settings: 'GET|PUT /api/speech/settings',
} as const;

export interface SpeechRouteDependencies {
    readonly catalog: HandySpeechCatalog;
    readonly pinnedEngineVersion: string;
    readonly downloads: SpeechDownloadManager;
    readonly settings: SpeechSettingsStore;
    /** Build the picker rows (grades, speed, engine gate, install state). */
    readonly listModels: () => Promise<SpeechModelListResponse>;
    /** Fully local WAV → transcript through the existing HexSpeechAdapter. */
    readonly transcribe: (request: SpeechTranscriptionRequest) => Promise<SpeechTranscriptionResponse>;
    /** Push a download snapshot to the connected WS clients. */
    readonly pushDownloadEvent: (snapshot: import('../services/speech/types.js').SpeechDownloadSnapshot) => void;
}

/**
 * Mount the speech API into the existing Express app.
 *
 * Auth: every mutating route already requires the per-launch X-Auth-Token via
 * app.ts's global middleware. GET /api/speech/models is public like the model
 * catalog; GET /api/speech/settings is user data and must be added to
 * PROTECTED_READ_PREFIXES (or gated inside this router) by Stage 2.
 *
 * The transcribe route must use `express.raw({ type: 'audio/wav', limit })`
 * scoped to that route, NOT the app-wide 256 kb JSON parser.
 */
export function createSpeechRouter(_deps: SpeechRouteDependencies): Router {
    throw new Error('TODO(stage2): build the Express Router for SPEECH_ROUTES and wire progress → WS.');
}
