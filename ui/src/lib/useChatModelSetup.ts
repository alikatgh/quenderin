import { useCallback, useEffect, useRef, useState } from 'react';
import { apiFetch } from './api.js';

export interface ChatModel {
    id: string;
    label: string;
    sizeLabel: string;
    isDownloaded: boolean;
    runtimeCompatible: boolean;
    runtimeMessage?: string;
}

export interface PendingChatActivation {
    modelId: string;
    status: 'pending' | 'activating' | 'failed';
    code?: string | null;
    error: string | null;
}

interface ChatCatalogResponse {
    catalog: ChatModel[];
    activeModelId: string | null;
    downloadingModelId?: string | null;
    downloadingActivate?: boolean;
    pendingActivation?: PendingChatActivation | null;
}

const CHAT_ACTIVATION_POLL_MS = 1500;

export function useChatModelSetup(
    wsDownloadingId: string | null,
    wsProgress: number,
    enabled = true,
) {
    const [models, setModels] = useState<ChatModel[] | null>(null);
    const [activeModelId, setActiveModelId] = useState<string | null>(null);
    const [downloadingModelId, setDownloadingModelId] = useState<string | null>(null);
    const [downloadingActivate, setDownloadingActivate] = useState(false);
    const [pendingActivation, setPendingActivation] = useState<PendingChatActivation | null>(null);
    const [trackedModelId, setTrackedModelId] = useState<string | null>(null);
    const [loadError, setLoadError] = useState<string | null>(null);
    const [retrying, setRetrying] = useState(false);
    const [retryError, setRetryError] = useState<string | null>(null);
    const requestSeqRef = useRef(0);
    const prevProgressRef = useRef(wsProgress);
    const modelsRef = useRef<ChatModel[] | null>(models);
    modelsRef.current = models;

    const refresh = useCallback(async (signal?: AbortSignal): Promise<ChatCatalogResponse | null> => {
        if (!enabled) return null;
        const seq = ++requestSeqRef.current;
        try {
            const response = await apiFetch('/api/models/catalog', { signal });
            if (!response.ok) throw new Error('Could not load local chat models.');
            const result = await response.json() as ChatCatalogResponse;
            if (signal?.aborted || seq !== requestSeqRef.current) return null;
            setModels(result.catalog ?? []);
            setActiveModelId(result.activeModelId ?? null);
            const serverDownloading = result.downloadingModelId ?? null;
            const serverPending = result.pendingActivation ?? null;
            setDownloadingModelId(serverDownloading);
            setDownloadingActivate(result.downloadingActivate === true && Boolean(serverDownloading));
            setPendingActivation(serverPending);
            setLoadError(null);
            setTrackedModelId(current => {
                if (!current) return null;
                if (serverDownloading === current) return current;
                if (serverPending && serverPending.modelId === current) return current;
                return null;
            });
            return result;
        } catch {
            if (!signal?.aborted && seq === requestSeqRef.current) {
                setLoadError('Could not load local chat models.');
            }
            return null;
        }
    }, [enabled]);

    useEffect(() => {
        if (!enabled) return;
        const controller = new AbortController();
        void refresh(controller.signal);
        return () => controller.abort();
    }, [enabled, refresh]);

    useEffect(() => {
        const previous = prevProgressRef.current;
        prevProgressRef.current = wsProgress;
        if (enabled && wsProgress === 100 && previous < 100) {
            void refresh();
        }
    }, [enabled, wsProgress, refresh]);

    const shouldPoll = enabled && Boolean(
        downloadingModelId
        || pendingActivation?.status === 'pending'
        || pendingActivation?.status === 'activating'
        || (trackedModelId && pendingActivation?.status !== 'failed')
        || (wsDownloadingId && wsProgress > 0 && wsProgress < 100),
    );

    useEffect(() => {
        if (!shouldPoll) return;
        const timer = window.setInterval(() => {
            void refresh();
        }, CHAT_ACTIVATION_POLL_MS);
        return () => window.clearInterval(timer);
    }, [shouldPoll, refresh]);

    const selectModel = useCallback(async (model: Pick<ChatModel, 'id' | 'isDownloaded'>): Promise<void> => {
        const path = model.isDownloaded ? 'switch' : 'download';
        const response = await apiFetch(`/api/models/${path}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(model.isDownloaded ? { modelId: model.id } : { modelId: model.id, activate: true }),
        });
        if (!response.ok) {
            const result = await response.json().catch(() => null);
            if (result?.activeDownloadModelId) {
                setDownloadingModelId(String(result.activeDownloadModelId));
            }
            throw new Error(result?.error ?? 'Could not select the local chat model.');
        }
        // Invalidate any stale catalog GET that raced with this write.
        ++requestSeqRef.current;
        setRetryError(null);
        if (model.isDownloaded) {
            setActiveModelId(model.id);
            setTrackedModelId(null);
            setPendingActivation(current => current?.modelId === model.id ? null : current);
        } else {
            setDownloadingModelId(model.id);
            setDownloadingActivate(true);
            setTrackedModelId(model.id);
            setPendingActivation(current => current?.modelId === model.id ? null : current);
        }
    }, []);

    const retryPendingActivation = useCallback(async (): Promise<void> => {
        const targetId = pendingActivation?.modelId;
        if (!targetId) return;
        setRetrying(true);
        setRetryError(null);
        try {
            const latest = modelsRef.current?.find(m => m.id === targetId);
            await selectModel({ id: targetId, isDownloaded: latest?.isDownloaded === true });
            void refresh();
        } catch (cause) {
            setRetryError(cause instanceof Error ? cause.message : 'Could not retry the local chat model.');
        } finally {
            setRetrying(false);
        }
    }, [pendingActivation?.modelId, selectModel, refresh]);

    const modelLabel = useCallback((modelId: string | null): string | null => {
        if (!modelId) return null;
        return models?.find(m => m.id === modelId)?.label ?? modelId;
    }, [models]);

    return {
        models,
        activeModelId,
        downloadingModelId,
        downloadingActivate,
        pendingActivation,
        trackedModelId,
        loadError,
        retrying,
        retryError,
        wsDownloadingId,
        wsProgress,
        refresh,
        selectModel,
        retryPendingActivation,
        modelLabel,
    };
}

export type ChatModelSetup = ReturnType<typeof useChatModelSetup>;
