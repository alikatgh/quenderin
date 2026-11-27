import express, { type ErrorRequestHandler, type Request, type Response } from 'express';
import { rateLimit } from 'express-rate-limit';
import { SPEECH_TRANSCRIPTION_TIMEOUT_MS } from '../services/hexSpeechAdapter.js';
import { findCatalogModel } from '../services/speech/catalog.js';
import type { SpeechDownloadManager } from '../services/speech/downloadManager.js';
import { SpeechError } from '../services/speech/errors.js';
import { buildModelSummary } from '../services/speech/grading.js';
import { parseSpeechSettingsPatch, type SpeechSettingsStore } from '../services/speech/speechSettings.js';
import { assertModelTranscribable, validateTranscriptionAudio } from '../services/speech/transcribe.js';
import type { HandySpeechCatalog, SpeechTranscriptionRequest, SpeechTranscriptionResponse } from '../services/speech/types.js';

export interface SpeechRouteDependencies {
    readonly catalog: HandySpeechCatalog;
    readonly pinnedEngineVersion: string;
    readonly maxAudioBytes: number;
    readonly uploadTimeoutMs?: number;
    readonly downloads: SpeechDownloadManager;
    readonly settings: SpeechSettingsStore;
    readonly transcribe: (request: SpeechTranscriptionRequest, signal: AbortSignal) => Promise<SpeechTranscriptionResponse>;
}

const DEFAULT_UPLOAD_TIMEOUT_MS = 15_000;

function requireParamString(value: unknown, code: string, message: string): string {
    if (Array.isArray(value) || typeof value !== 'string' || !value) {
        throw new SpeechError(code, 400, message);
    }
    return value;
}

export function createSpeechRouter(deps: SpeechRouteDependencies): express.Router {
    const { catalog, pinnedEngineVersion, maxAudioBytes, downloads, settings } = deps;
    const uploadTimeoutMs = Math.max(10, deps.uploadTimeoutMs ?? DEFAULT_UPLOAD_TIMEOUT_MS);
    const router = express.Router();
    router.use((_req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });

    router.get('/models', async (_req, res) => {
        const models = [];
        for (const model of catalog.curatedModels) {
            const snapshot = await downloads.verifyInstalled(model.id).catch(() => null);
            models.push(buildModelSummary(catalog, model, pinnedEngineVersion, snapshot?.phase === 'installed'));
        }
        const picks = catalog.recommend(['en'], { engineVersion: pinnedEngineVersion });
        res.json({
            runtimeEngineVersion: pinnedEngineVersion, methodology: catalog.methodology, models,
            recommendedModelId: picks.find(pick => pick.roles.includes('best'))?.model.id ?? null,
            accurateModelId: picks.find(pick => pick.roles.includes('accurate'))?.model.id ?? null,
        });
    });

    router.post('/downloads', async (req, res) => {
        const body = req.body && typeof req.body === 'object' && !Array.isArray(req.body)
            ? req.body as Record<string, unknown>
            : null;
        const modelId = body?.modelId;
        if (Array.isArray(modelId) || typeof modelId !== 'string' || !modelId) {
            throw new SpeechError('invalid-model', 400, 'Choose a speech model.');
        }
        res.status(202).json(await downloads.start(modelId));
    });

    router.get('/downloads', (_req, res) => {
        res.json(downloads.snapshots());
    });

    router.get('/downloads/:modelId', async (req, res) => {
        const modelId = requireParamString(req.params.modelId, 'invalid-model', 'Choose a speech model.');
        const snapshot = await downloads.status(modelId);
        if (!snapshot) throw new SpeechError('download-not-found', 404, 'This speech model has no download.');
        res.json(snapshot);
    });

    for (const action of ['pause', 'resume', 'cancel', 'retry'] as const) {
        router.post(`/downloads/:modelId/${action}`, async (req, res) => {
            const modelId = requireParamString(req.params.modelId, 'invalid-model', 'Choose a speech model.');
            res.json(await downloads[action](modelId));
        });
    }

    router.delete('/models/:modelId', async (req, res) => {
        const modelId = requireParamString(req.params.modelId, 'invalid-model', 'Choose a speech model.');
        const snapshot = await downloads.remove(modelId);
        const currentSettings = await settings.clearModel(modelId);
        res.json({ snapshot, settings: currentSettings });
    });

    router.get('/settings', async (_req, res) => { res.json(await settings.get()); });
    router.put('/settings', async (req, res) => {
        let patch;
        try { patch = parseSpeechSettingsPatch(req.body); } catch {
            throw new SpeechError('invalid-settings', 400, 'Invalid voice settings.');
        }
        if (patch.modelId !== undefined && patch.modelId !== null) {
            if (!findCatalogModel(catalog, patch.modelId)) throw new SpeechError('unknown-model', 400, 'Unknown speech model.');
            if (patch.voiceEnabled !== false) assertModelTranscribable(catalog, patch.modelId, pinnedEngineVersion);
        }
        res.json(await settings.update(patch));
    });

    const parseWav = express.raw({ type: 'audio/wav', limit: maxAudioBytes, inflate: false });
    let transcribing = false;
    router.post('/transcribe', rateLimit({
        windowMs: 60_000, limit: 60, standardHeaders: true, legacyHeaders: false,
        message: { error: 'Too many recordings. Wait a moment and try again.', code: 'rate-limited' },
    }), (req, res, next) => {
        if (!req.is('audio/wav')) {
            next(new SpeechError('invalid-audio', 415, 'Send audio with Content-Type audio/wav.'));
            return;
        }
        const declaredLength = req.headers['content-length'];
        if (Array.isArray(declaredLength)) {
            next(new SpeechError('invalid-audio', 400, 'Invalid Content-Length header.'));
            return;
        }
        if (typeof declaredLength === 'string' && /^\d+$/.test(declaredLength) && Number(declaredLength) > maxAudioBytes) {
            next(new SpeechError('audio-too-large', 413, 'The recording is too large.'));
            return;
        }
        const rawQueryModelId = req.query.modelId;
        if (rawQueryModelId !== undefined && (Array.isArray(rawQueryModelId) || typeof rawQueryModelId !== 'string' || !rawQueryModelId)) {
            next(new SpeechError('invalid-model', 400, 'Invalid speech model.'));
            return;
        }
        const rawQueryLanguage = req.query.language;
        if (rawQueryLanguage !== undefined && (Array.isArray(rawQueryLanguage) || typeof rawQueryLanguage !== 'string' || !/^[a-z0-9_-]{1,32}$/i.test(rawQueryLanguage))) {
            next(new SpeechError('invalid-language', 400, 'Invalid speech language.'));
            return;
        }
        if (transcribing) {
            next(new SpeechError('speech-busy', 409, 'A transcription is already in progress.'));
            return;
        }
        transcribing = true;
        let released = false;
        let parsing = true;
        let settled = false;
        const controller = new AbortController();
        const release = () => {
            if (released) return;
            released = true;
            clearTimeout(uploadTimer);
            transcribing = false;
        };
        const abortUpload = () => {
            controller.abort();
            if (parsing) {
                settled = true;
                release();
                if (!req.destroyed) req.destroy();
            }
        };
        const uploadTimer = setTimeout(() => {
            if (!parsing || settled) return;
            settled = true;
            controller.abort();
            release();
            if (!res.headersSent && !res.destroyed) {
                res.status(408).json({ code: 'upload-timeout', error: 'Audio upload timed out before completing.' });
            }
            if (!req.destroyed) req.destroy();
        }, uploadTimeoutMs);
        uploadTimer.unref?.();
        req.once('aborted', abortUpload);
        res.once('close', () => {
            if (!res.writableEnded) abortUpload();
        });
        parseWav(req, res, error => {
            parsing = false;
            clearTimeout(uploadTimer);
            if (settled) return;
            if (error) {
                settled = true;
                release();
                next(error);
                return;
            }
            void transcribe(req, res, controller.signal, rawQueryModelId, rawQueryLanguage)
                .catch(next)
                .finally(release);
        });
    });

    async function transcribe(
        req: Request,
        res: Response,
        signal: AbortSignal,
        queryModelId: string | undefined,
        queryLanguage: string | undefined,
    ) {
        const rawBody: unknown = req.body;
        if (typeof rawBody === 'string' || Array.isArray(rawBody) || !Buffer.isBuffer(rawBody)) {
            throw new SpeechError('invalid-audio', 415, 'Send a non-empty WAV recording.');
        }
        const wav = Buffer.from(rawBody.buffer, rawBody.byteOffset, rawBody.byteLength);
        validateTranscriptionAudio(wav, maxAudioBytes);
        const saved = await settings.get();
        const modelId = queryModelId ?? saved.modelId;
        if (typeof modelId !== 'string' || !modelId) throw new SpeechError('voice-disabled', 409, 'Enable a voice model in Settings.');
        assertModelTranscribable(catalog, modelId, pinnedEngineVersion);
        if (!saved.voiceEnabled || saved.modelId !== modelId) {
            throw new SpeechError('voice-disabled', 409, 'Choose and enable this voice model in Settings.');
        }
        if ((await downloads.status(modelId))?.phase !== 'installed') {
            throw new SpeechError('model-not-installed', 409, 'Download the selected voice model before dictating.');
        }
        res.setTimeout(SPEECH_TRANSCRIPTION_TIMEOUT_MS + 30_000);
        const result = await deps.transcribe({ wav, modelId, language: queryLanguage, autoSend: saved.autoSend }, signal);
        if (!signal.aborted && !res.destroyed) res.json(result);
    }

    const handleError: ErrorRequestHandler = (error: unknown, _req, res, _next) => {
        if (res.destroyed) return;
        if (error instanceof SpeechError) {
            res.status(error.status).json({ error: error.message, code: error.code });
            return;
        }
        const parser = error as { type?: string; status?: number } | undefined;
        if (parser?.status === 413 || parser?.status === 415 || parser?.status === 400) {
            const code = parser.status === 413 ? 'audio-too-large' : 'invalid-audio';
            res.status(parser.status).json({ code, error: parser.status === 413 ? 'The recording is too large.' : 'Invalid WAV request body.' });
            return;
        }
        const classified = downloads.classifyError(error);
        res.status(classified.kind === 'disk-full' ? 507 : 500).json({ error: classified.message, code: classified.kind });
    };
    router.use(handleError);
    return router;
}
