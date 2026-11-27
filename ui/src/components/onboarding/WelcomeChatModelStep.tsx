import { useEffect, useState } from 'react';
import { ArrowRight, BrainCircuit, Download } from 'lucide-react';
import { apiFetch } from '../../lib/api.js';
import { DownloadWaitPlayground } from '../DownloadWaitPlayground.js';

interface ChatModel {
    id: string;
    label: string;
    sizeLabel: string;
    isDownloaded: boolean;
    runtimeCompatible: boolean;
    runtimeMessage?: string;
}

export function WelcomeChatModelStep({ onContinue, onImages, onVision, recommendedModelId, downloadingId, progress }: {
    onContinue: () => void;
    onImages: () => void;
    onVision: () => void;
    recommendedModelId?: string;
    downloadingId: string | null;
    progress: number;
}) {
    const [models, setModels] = useState<ChatModel[] | null>(null);
    const [activeId, setActiveId] = useState<string | null>(null);
    const [pickedId, setPickedId] = useState<string | null>(null);
    const [startedId, setStartedId] = useState<string | null>(null);
    const [busy, setBusy] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const installed = progress === 100;
    const [reload, setReload] = useState(0);

    useEffect(() => {
        const controller = new AbortController();
        void apiFetch('/api/models/catalog', { signal: controller.signal })
            .then(async response => {
                if (!response.ok) throw new Error('Could not load local chat models.');
                const result: { catalog: ChatModel[]; activeModelId: string } = await response.json();
                if (controller.signal.aborted) return;
                setModels(result.catalog);
                setActiveId(result.activeModelId);
            }).catch(() => { if (!controller.signal.aborted) setError('Could not load local chat models.'); });
        return () => controller.abort();
    }, [installed, reload]);

    const selected = models?.find(m => m.id === pickedId)
        ?? models?.find(m => m.id === activeId && m.isDownloaded && m.runtimeCompatible)
        ?? models?.find(m => m.id === recommendedModelId && m.runtimeCompatible)
        ?? models?.find(m => m.runtimeCompatible);
    const downloading = !!selected && !selected.isDownloaded &&
        (selected.id === startedId || (downloadingId === selected.id && progress > 0 && !installed));

    async function chooseModel(continueAfter: boolean) {
        if (!selected) return;
        setBusy(true);
        setError(null);
        try {
            const path = selected.isDownloaded ? 'switch' : 'download';
            const response = await apiFetch(`/api/models/${path}`, {
                method: 'POST', headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(selected.isDownloaded ? { modelId: selected.id } : { modelId: selected.id, activate: true }),
            });
            if (!response.ok) {
                const result = await response.json().catch(() => null);
                throw new Error(result?.error ?? 'Could not select the local chat model.');
            }
            if (selected.isDownloaded) setActiveId(selected.id);
            else setStartedId(selected.id);
            if (continueAfter) onContinue();
        } catch (cause) {
            setError(cause instanceof Error ? cause.message : 'Could not select the local chat model.');
        } finally { setBusy(false); }
    }

    function next() {
        if (selected && !downloading && (!selected.isDownloaded || activeId !== selected.id)) void chooseModel(true);
        else onContinue();
    }

    const textButton = 'rounded-lg px-3 py-2 text-sm font-medium text-qteal-700 hover:bg-zinc-100 dark:text-qteal-300 dark:hover:bg-zinc-800';
    return (
        <section aria-labelledby="welcome-chat-model" className="space-y-4">
            <div>
                <BrainCircuit aria-hidden="true" className="mb-3 size-6 text-qteal-600 dark:text-qteal-300" />
                <h2 id="welcome-chat-model" className="text-lg font-semibold">Choose your local chat model</h2>
                <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">Your chat model runs on this computer. You can change it in Settings.</p>
            </div>
            {selected ? (
                <label className="block text-sm font-medium">Chat model
                    <select className="mt-1 block w-full rounded-lg border border-zinc-300 bg-white p-2 dark:border-zinc-600 dark:bg-zinc-900"
                        value={selected.id} disabled={busy || downloading} onChange={event => { setPickedId(event.target.value); setError(null); }}>
                        {models?.map(model => (
                            <option key={model.id} value={model.id} disabled={!model.runtimeCompatible}>
                                {model.label}{model.isDownloaded ? ' · Installed' : ` · ${model.sizeLabel}`}
                            </option>
                        ))}
                    </select>
                </label>
            ) : error ? <button type="button" className={textButton} onClick={() => { setError(null); setReload(n => n + 1); }}>Retry loading chat models</button>
                : <p role="status" className="text-sm">{models ? 'No compatible local chat models found.' : 'Loading chat models…'}</p>}
            {error && <p role="alert" className="text-sm text-red-700 dark:text-red-300">{error}</p>}
            {downloading && progress > 0 && progress < 100 && downloadingId === selected.id && <DownloadWaitPlayground progress={progress} />}
            {selected && !selected.isDownloaded && (
                <button type="button" disabled={busy} className={textButton} onClick={() => void chooseModel(false)}>
                    <Download aria-hidden="true" className="me-1 inline size-4" />
                    {downloading ? 'Retry download' : 'Download chat model'}
                </button>
            )}
            <button type="button" disabled={busy} onClick={next}
                className="flex w-full items-center justify-center gap-2 rounded-xl bg-zinc-900 px-4 py-2.5 text-sm font-semibold text-white disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900">
                {downloading ? 'Continue while downloading' : 'Next: Voice'} <ArrowRight aria-hidden="true" className="size-4" />
            </button>
            <div className="flex flex-wrap justify-center gap-1">
                {selected && !selected.isDownloaded && !downloading && <button type="button" onClick={onContinue} className={textButton}>Set up chat later</button>}
                <button type="button" onClick={onImages} className={textButton}>Use images first</button>
                <button type="button" onClick={onVision} className={textButton}>Ask about an image</button>
            </div>
        </section>
    );
}
