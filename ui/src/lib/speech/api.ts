import { apiFetch } from '../api.js';
import type {
    SpeechDownloadSnapshot, SpeechModelListResponse, SpeechSettingsResponse,
    SpeechTranscriptionResponse, UpdateSpeechSettingsRequest,
} from './types.js';

export interface TranscribeOptions {
    readonly modelId: string;
    readonly language?: string;
    readonly signal?: AbortSignal;
}

export interface SpeechApi {
    listModels(signal?: AbortSignal): Promise<SpeechModelListResponse>;
    listDownloads(): Promise<readonly SpeechDownloadSnapshot[]>;
    startDownload(modelId: string): Promise<SpeechDownloadSnapshot>;
    getDownload(modelId: string): Promise<SpeechDownloadSnapshot>;
    pauseDownload(modelId: string): Promise<SpeechDownloadSnapshot>;
    resumeDownload(modelId: string): Promise<SpeechDownloadSnapshot>;
    cancelDownload(modelId: string): Promise<SpeechDownloadSnapshot>;
    retryDownload(modelId: string): Promise<SpeechDownloadSnapshot>;
    removeModel(modelId: string): Promise<SpeechDownloadSnapshot>;
    getSettings(): Promise<SpeechSettingsResponse>;
    updateSettings(patch: UpdateSpeechSettingsRequest): Promise<SpeechSettingsResponse>;
    transcribe(wav: Blob, options: TranscribeOptions): Promise<SpeechTranscriptionResponse>;
}

export class SpeechApiError extends Error {
    constructor(message: string, readonly status: number, readonly code: string) {
        super(message);
        this.name = 'SpeechApiError';
    }
}

export function createSpeechApi({ fetchImpl = apiFetch }: { fetchImpl?: typeof apiFetch } = {}): SpeechApi {
    async function request<T>(path: string, init?: RequestInit): Promise<T> {
        const response = await fetchImpl('/api/speech' + path, init);
        if (!response.ok) {
            const value = await response.json().catch(() => null);
            throw new SpeechApiError(
                typeof value?.error === 'string' ? value.error : `Speech request failed (${response.status}).`,
                response.status, typeof value?.code === 'string' ? value.code : 'unknown',
            );
        }
        return response.json();
    }
    const json = (method: string, body: object): RequestInit => ({
        method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    });
    const download = (id: string) => '/downloads/' + encodeURIComponent(id);
    return {
        listModels: signal => request('/models', { signal }),
        listDownloads: () => request('/downloads'),
        startDownload: modelId => request('/downloads', json('POST', { modelId })),
        getDownload: id => request(download(id)),
        pauseDownload: id => request(download(id) + '/pause', { method: 'POST' }),
        resumeDownload: id => request(download(id) + '/resume', { method: 'POST' }),
        cancelDownload: id => request(download(id) + '/cancel', { method: 'POST' }),
        retryDownload: id => request(download(id) + '/retry', { method: 'POST' }),
        removeModel: id => request('/models/' + encodeURIComponent(id), { method: 'DELETE' }),
        getSettings: () => request('/settings'),
        updateSettings: patch => request('/settings', json('PUT', patch)),
        transcribe: (wav, { modelId, language, signal }) => {
            const params = new URLSearchParams({ modelId });
            if (language) params.set('language', language);
            return request('/transcribe?' + params, {
                method: 'POST', headers: { 'Content-Type': 'audio/wav' }, body: wav, signal,
            });
        },
    };
}

export const speechApi = createSpeechApi();
