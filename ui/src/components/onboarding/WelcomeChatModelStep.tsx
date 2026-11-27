import { useState } from 'react';
import { ArrowRight, BrainCircuit, Download } from 'lucide-react';
import type { ChatModelSetup } from '../../lib/useChatModelSetup.js';
import { DownloadWaitPlayground } from '../DownloadWaitPlayground.js';

export function WelcomeChatModelStep({
    chat,
    onContinue,
    onImages,
    onVision,
    recommendedModelId,
    downloadingId,
    progress,
}: {
    chat: ChatModelSetup;
    onContinue: () => void;
    onImages: () => void;
    onVision: () => void;
    recommendedModelId?: string;
    downloadingId: string | null;
    progress: number;
}) {
    const [pickedId, setPickedId] = useState<string | null>(null);
    const [busy, setBusy] = useState(false);
    const [error, setError] = useState<string | null>(null);

    const { models, activeModelId: activeId, downloadingModelId: serverDownloadingId, downloadingActivate, pendingActivation, trackedModelId, loadError } = chat;
    const wsActiveId = progress > 0 && progress < 100 && (!pendingActivation || pendingActivation.modelId !== downloadingId || pendingActivation.status !== 'failed')
        ? downloadingId
        : null;
    const activeDownloadId = serverDownloadingId ?? wsActiveId;
    const selected = models?.find(m => m.id === pickedId)
        ?? models?.find(m => m.id === activeDownloadId && m.runtimeCompatible)
        ?? models?.find(m => m.id === pendingActivation?.modelId && m.runtimeCompatible)
        ?? models?.find(m => m.id === trackedModelId && m.runtimeCompatible)
        ?? models?.find(m => m.id === activeId && m.isDownloaded && m.runtimeCompatible)
        ?? models?.find(m => m.id === recommendedModelId && m.runtimeCompatible)
        ?? models?.find(m => m.runtimeCompatible);
    const selectedFailed = !!selected && pendingActivation?.status === 'failed' && pendingActivation.modelId === selected.id;
    const downloading = !!selected && !selected.isDownloaded && !selectedFailed
        && (selected.id === serverDownloadingId || (wsActiveId === selected.id && serverDownloadingId === null));
    const activationRegistered = !!selected && (
        (downloadingActivate && serverDownloadingId === selected.id)
        || trackedModelId === selected.id
    );
    const otherDownload = !!activeDownloadId && !!selected && activeDownloadId !== selected.id;
    const activationFailure = pendingActivation?.status === 'failed' && (!selected || pendingActivation.modelId === selected.id)
        ? pendingActivation.error
        : null;
    const activationWaiting = (pendingActivation?.status === 'pending' || pendingActivation?.status === 'activating')
        && (!selected || pendingActivation.modelId === selected.id)
        ? (pendingActivation.error ?? 'Activating downloaded chat model…')
        : null;

    async function chooseModel(continueAfter: boolean) {
        if (!selected) return;
        setBusy(true);
        setError(null);
        try {
            await chat.selectModel(selected);
            if (continueAfter) onContinue();
        } catch (cause) {
            setError(cause instanceof Error ? cause.message : 'Could not select the local chat model.');
        } finally {
            setBusy(false);
        }
    }

    function next() {
        if (selected && (!selected.isDownloaded || activeId !== selected.id)) {
            if (!downloading || !activationRegistered) {
                void chooseModel(true);
                return;
            }
        }
        onContinue();
    }

    const displayError = error ?? (selected ? null : loadError) ?? activationFailure;
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
            ) : displayError ? <button type="button" className={textButton} onClick={() => { setError(null); void chat.refresh(); }}>Retry loading chat models</button>
                : <p role="status" className="text-sm">{models ? 'No compatible local chat models found.' : 'Loading chat models…'}</p>}
            {displayError && <p role="alert" className="text-sm text-red-700 dark:text-red-300">{displayError}</p>}
            {activationWaiting && <p role="status" className="text-xs text-zinc-600 dark:text-zinc-400">{activationWaiting}</p>}
            {otherDownload && !error && <p role="status" className="text-xs text-amber-800 dark:text-amber-300">Another chat model download is already in progress. Wait for it to finish before starting a different model.</p>}
            {downloading && progress > 0 && progress < 100 && downloadingId === selected.id && <DownloadWaitPlayground progress={progress} />}
            {selected && (!selected.isDownloaded || selectedFailed) && (
                <button type="button" disabled={busy} className={textButton} onClick={() => void chooseModel(false)}>
                    <Download aria-hidden="true" className="me-1 inline size-4" />
                    {selectedFailed ? 'Retry chat model' : downloading ? 'Retry download' : 'Download chat model'}
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
