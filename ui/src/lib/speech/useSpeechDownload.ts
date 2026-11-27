import { useCallback, useEffect, useState } from 'react';
import { speechApi, SpeechApiError } from './api.js';
import type { SpeechDownloadSnapshot } from './types.js';

const activePhases = new Set(['queued', 'downloading', 'verifying']);
export const isSpeechDownloadActive = (snapshot: SpeechDownloadSnapshot | undefined | null): boolean =>
    !!snapshot && activePhases.has(snapshot.phase);

export function mergeSpeechSnapshot(
    current: Readonly<Record<string, SpeechDownloadSnapshot>>,
    snapshot: SpeechDownloadSnapshot,
): Readonly<Record<string, SpeechDownloadSnapshot>> {
    const previous = current[snapshot.modelId];
    if (previous && snapshot.updatedAt <= previous.updatedAt) return current;
    return { ...current, [snapshot.modelId]: snapshot };
}

export function useSpeechDownload(
    connected: boolean,
    events: Readonly<Record<string, SpeechDownloadSnapshot>>,
    api = speechApi,
) {
    const [restSnapshots, setRestSnapshots] = useState<Readonly<Record<string, SpeechDownloadSnapshot>>>({});
    const accept = useCallback((snapshot: SpeechDownloadSnapshot) => {
        setRestSnapshots(current => mergeSpeechSnapshot(current, snapshot));
    }, []);
    const refresh = useCallback(async (modelId: string) => {
        try { accept(await api.getDownload(modelId)); } catch (error) {
            if (!(error instanceof SpeechApiError && error.status === 404)) throw error;
        }
    }, [api, accept]);

    useEffect(() => {
        let live = true;
        const load = () => {
            void api.listDownloads().then(rows => {
                if (live) setRestSnapshots(current => rows.reduce(mergeSpeechSnapshot, current));
            }).catch(() => {});
        };
        load();
        const fallback = connected ? undefined : window.setInterval(load, 2500);
        return () => { live = false; window.clearInterval(fallback); };
    }, [connected, api]);

    const snapshots = Object.values(events).reduce(mergeSpeechSnapshot, restSnapshots);
    const run = async (action: 'start' | 'pause' | 'resume' | 'cancel' | 'retry' | 'remove', modelId: string) => {
        const commands = {
            start: api.startDownload, pause: api.pauseDownload, resume: api.resumeDownload,
            cancel: api.cancelDownload, retry: api.retryDownload, remove: api.removeModel,
        };
        try {
            accept(await commands[action](modelId));
        } catch (error) {
            if (!(action === 'start' && error instanceof SpeechApiError && error.code === 'already-installed')) throw error;
            await refresh(modelId);
        }
    };
    return { snapshots, refresh, run };
}
