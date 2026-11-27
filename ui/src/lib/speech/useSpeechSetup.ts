import { useCallback, useEffect, useMemo, useState } from 'react';
import { speechApi } from './api.js';
import type {
    SpeechDownloadSnapshot, SpeechModelListResponse, SpeechSettingsResponse, UpdateSpeechSettingsRequest,
} from './types.js';
import { useSpeechDownload } from './useSpeechDownload.js';

export function useSpeechSetup(connected: boolean, events: Readonly<Record<string, SpeechDownloadSnapshot>>) {
    const downloads = useSpeechDownload(connected, events);
    const [catalog, setCatalog] = useState<SpeechModelListResponse | null>(null);
    const [settings, setSettings] = useState<SpeechSettingsResponse | null>(null);
    const [loadError, setLoadError] = useState<string | null>(null);
    const { refresh } = downloads;
    const load = useCallback(async (signal?: AbortSignal) => {
        setLoadError(null);
        try {
            const [catalog, settings] = await Promise.all([speechApi.listModels(signal), speechApi.getSettings()]);
            if (signal?.aborted) return;
            setCatalog(catalog);
            setSettings(settings);
        } catch (error) {
            if (!signal?.aborted) setLoadError(error instanceof Error ? error.message : 'Could not load voice models.');
        }
    }, []);
    useEffect(() => {
        const controller = new AbortController();
        void load(controller.signal);
        return () => controller.abort();
    }, [load, connected]);
    useEffect(() => {
        if (settings?.modelId) void refresh(settings.modelId).catch(() => {});
    }, [settings?.modelId, refresh, connected]);

    function acceptSettings(next: SpeechSettingsResponse) {
        setSettings(current => !current || current.updatedAt <= next.updatedAt ? next : current);
    }
    async function updateSettings(patch: UpdateSpeechSettingsRequest) {
        acceptSettings(await speechApi.updateSettings(patch));
    }
    async function removeModel(modelId: string) {
        acceptSettings(await downloads.remove(modelId));
    }
    const rows = useMemo(() => catalog && {
        ...catalog,
        models: catalog.models.map(row => {
            const snapshot = downloads.snapshots[row.model.id];
            return snapshot
                ? { ...row, installed: snapshot.phase === 'installed', installedBytes: snapshot.phase === 'installed' ? snapshot.totalBytes : null }
                : row;
        }),
    }, [catalog, downloads.snapshots]);
    const refreshDownload = useCallback((id: string) => { void refresh(id).catch(() => {}); }, [refresh]);
    return { downloads, catalog: rows, settings, updateSettings, removeModel, loadError, load, refreshDownload };
}

export type SpeechSetup = ReturnType<typeof useSpeechSetup>;
