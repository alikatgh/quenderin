import type { ChatModelSetup } from '../../lib/useChatModelSetup.js';

export function ChatModelActivationBanner({
    chat,
    onOpenSettings,
    compact = false,
}: {
    chat: ChatModelSetup;
    onOpenSettings?: () => void;
    compact?: boolean;
}) {
    const { pendingActivation, downloadingModelId, trackedModelId, wsDownloadingId, wsProgress, retrying, retryError } = chat;
    const failed = pendingActivation?.status === 'failed' ? pendingActivation : null;
    const waiting = pendingActivation && (pendingActivation.status === 'pending' || pendingActivation.status === 'activating')
        ? pendingActivation
        : null;
    const activeDownloadId = !failed && !waiting
        ? (downloadingModelId ?? (trackedModelId && wsDownloadingId === trackedModelId && wsProgress > 0 && wsProgress < 100 ? trackedModelId : null))
        : null;

    if (!failed && !waiting && !activeDownloadId) return null;

    const containerClass = compact
        ? 'rounded-xl border px-3 py-2 text-xs'
        : 'flex shrink-0 flex-wrap items-center justify-between gap-2 border-b px-4 py-2 text-xs';

    if (failed) {
        const label = chat.modelLabel(failed.modelId) ?? failed.modelId;
        const message = retryError ?? failed.error ?? 'Could not activate the downloaded chat model.';
        return (
            <div
                role="alert"
                className={`${containerClass} border-red-200 bg-red-50 text-red-800 dark:border-red-900/60 dark:bg-red-950/40 dark:text-red-200`}
            >
                <div className="flex flex-wrap items-center justify-between gap-2">
                    <span>
                        <strong className="font-semibold">{label}:</strong> {message}
                    </span>
                    <span className="flex items-center gap-2">
                        <button
                            type="button"
                            disabled={retrying}
                            onClick={() => void chat.retryPendingActivation()}
                            className="shrink-0 rounded-lg border border-red-300 bg-white px-2.5 py-1 font-medium text-red-800 hover:bg-red-100 disabled:opacity-50 dark:border-red-800 dark:bg-zinc-900 dark:text-red-200 dark:hover:bg-red-950"
                        >
                            {retrying ? 'Retrying…' : 'Retry chat model'}
                        </button>
                        {onOpenSettings && (
                            <button
                                type="button"
                                onClick={onOpenSettings}
                                className="shrink-0 rounded px-2 py-1 font-medium underline"
                            >
                                Model settings
                            </button>
                        )}
                    </span>
                </div>
            </div>
        );
    }

    if (waiting) {
        const label = chat.modelLabel(waiting.modelId) ?? waiting.modelId;
        return (
            <div
                role="status"
                className={`${containerClass} border-zinc-200 bg-zinc-50 text-zinc-700 dark:border-zinc-800 dark:bg-zinc-900/60 dark:text-zinc-300`}
            >
                <span>
                    {waiting.error ?? `Activating ${label}…`}
                </span>
            </div>
        );
    }

    if (!activeDownloadId) return null;
    const label = chat.modelLabel(activeDownloadId) ?? activeDownloadId;
    const pct = wsDownloadingId === activeDownloadId && wsProgress > 0 && wsProgress < 100
        ? ` (${Math.round(wsProgress)}%)`
        : '';
    return (
        <div
            role="status"
            className={`${containerClass} border-zinc-200 bg-zinc-50 text-zinc-700 dark:border-zinc-800 dark:bg-zinc-900/60 dark:text-zinc-300`}
        >
            <span>Downloading chat model {label}{pct}…</span>
        </div>
    );
}
