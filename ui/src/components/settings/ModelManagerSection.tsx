import { useState, useEffect } from 'react';
import { BrainCircuit, CheckCircle2, Zap, HardDrive, Trash2, Download, AlertTriangle } from 'lucide-react';
import { apiFetch } from '../../lib/api.js';
import { RetryState } from '../RetryState.js';

/**
 * AI Model Manager — extracted from SettingsArea (r38/r44 split, 2026-07-11). Fully
 * self-contained: owns the catalog fetch, the download/switch/delete actions, and the
 * active-model pin. All state was moved verbatim; behavior is unchanged.
 */

interface ModelCatalogEntry {
    id: string;
    label: string;
    ramGb: number;
    sizeLabel: string;
    paramsBillions: number;
    quantization: string;
    isDownloaded: boolean;
    fileSizeBytes: number;
}

export function ModelManagerSection() {
    const [modelCatalog, setModelCatalog] = useState<ModelCatalogEntry[]>([]);
    // r10: an empty catalog is ambiguous — still loading, or the fetch failed (backend down,
    // expired token)? Without this the section said "Loading models..." FOREVER on failure.
    const [catalogState, setCatalogState] = useState<'loading' | 'error' | 'ready'>('loading');
    // r9 H1: the pinned/auto-selected model, from the catalog endpoint — drives the Active badge
    // and the Use button so a downloaded model can actually be made active from the UI.
    const [activeModelId, setActiveModelId] = useState<string | null>(null);
    const [modelActionId, setModelActionId] = useState<string | null>(null); // which model is being downloaded/deleted/activated
    const [modelActionType, setModelActionType] = useState<'download' | 'delete' | 'switch' | null>(null);
    // Q-528: the last failed model action, so a rejected download/delete (bad id, missing/expired token)
    // shows the user WHY instead of just clearing the spinner as if it had succeeded.
    const [modelActionError, setModelActionError] = useState<{ id: string; message: string } | null>(null);

    const refreshCatalog = () => {
        // Q-527: go through apiFetch (auth header + shared error handling) like every neighbouring call,
        // and guard on r.ok so a 5xx doesn't get JSON.parse'd as an error page and blank the catalog.
        apiFetch('/api/models/catalog')
            .then(r => r.ok ? r.json() : null)
            .then(d => {
                if (d) {
                    setModelCatalog(d.catalog ?? []);
                    setActiveModelId(d.activeModelId ?? null);
                    setCatalogState('ready');
                } else {
                    setCatalogState('error');
                }
            })
            .catch(() => setCatalogState('error'));
    };

    useEffect(() => {
        refreshCatalog();
    }, []);

    const handleDownloadModel = async (modelId: string) => {
        setModelActionId(modelId);
        setModelActionType('download');
        setModelActionError(null);
        try {
            // Q-528: surface a rejected START. The old code ignored res.ok, so a 400/401 (bad id, missing
            // or expired token) cleared the spinner as if the download had begun. Progress itself still
            // streams over the WS model_download_progress channel; this only reports the kickoff POST.
            const res = await apiFetch('/api/models/download', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ modelId }),
            });
            if (!res.ok) {
                const detail = await res.json().catch(() => null);
                setModelActionError({ id: modelId, message: detail?.error || `Download failed (${res.status})` });
            }
        } catch {
            setModelActionError({ id: modelId, message: 'Download failed — is the backend reachable?' });
        } finally {
            // Poll catalog after a short delay to pick up download status
            setTimeout(refreshCatalog, 2000);
            setModelActionId(null);
            setModelActionType(null);
        }
    };

    const handleSwitchModel = async (modelId: string) => {
        setModelActionId(modelId);
        setModelActionType('switch');
        setModelActionError(null);
        try {
            // One canonical switch path: REST, like every other model action here (the WS
            // switch_model twin was removed — dual unused paths had already drifted, r9 H1).
            const res = await apiFetch('/api/models/switch', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ modelId }),
            });
            if (!res.ok) {
                const detail = await res.json().catch(() => null);
                setModelActionError({ id: modelId, message: detail?.error || `Switch failed (${res.status})` });
            } else {
                setActiveModelId(modelId);
            }
        } catch {
            setModelActionError({ id: modelId, message: 'Switch failed — is the backend reachable?' });
        } finally {
            refreshCatalog();
            setModelActionId(null);
            setModelActionType(null);
        }
    };

    const handleDeleteModel = async (modelId: string) => {
        if (!confirm('Delete this model from disk? You will need to re-download it to use it again.')) return;
        setModelActionId(modelId);
        setModelActionType('delete');
        setModelActionError(null);
        try {
            const res = await apiFetch(`/api/models/${modelId}`, { method: 'DELETE' });
            if (!res.ok) {
                const detail = await res.json().catch(() => null);
                setModelActionError({ id: modelId, message: detail?.error || `Delete failed (${res.status})` });
            }
        } catch {
            setModelActionError({ id: modelId, message: 'Delete failed — is the backend reachable?' });
        } finally {
            setTimeout(refreshCatalog, 500);
            setModelActionId(null);
            setModelActionType(null);
        }
    };

    return (
        <section className="premium-card p-6">
            <div className="flex items-center gap-3 mb-5">
                <BrainCircuit className="w-5 h-5 text-emerald-500" />
                <div>
                    <h2 className="text-[15px] font-semibold text-zinc-900 dark:text-white">AI Model Manager</h2>
                    <p className="text-[12px] text-zinc-500 dark:text-zinc-400">Download or remove local AI models. All inference is 100% offline.</p>
                </div>
            </div>

            <div className="space-y-3">
                {catalogState === 'error' ? (
                    <RetryState
                        message="Couldn't load the model catalog — is the backend running?"
                        onRetry={() => { setCatalogState('loading'); refreshCatalog(); }}
                    />
                ) : modelCatalog.length === 0 ? (
                    <div className="text-sm text-zinc-500 dark:text-zinc-400 text-center py-4">Loading models...</div>
                ) : modelCatalog.map(m => {
                    const fileSizeGb = m.fileSizeBytes > 0 ? (m.fileSizeBytes / (1024 ** 3)).toFixed(2) : null;
                    const isActing = modelActionId === m.id;
                    // r12: flex-col on phones — the fixed side-by-side layout made the
                    // metadata line overflow INTO the action buttons at 375px.
                    return (
                        <div key={m.id} className={`flex flex-col sm:flex-row sm:items-center gap-3 sm:gap-4 p-4 rounded-xl border transition-all ${m.isDownloaded ? 'bg-emerald-50/50 dark:bg-emerald-900/10 border-emerald-200 dark:border-emerald-500/20' : 'bg-zinc-50 dark:bg-[#18181b] border-zinc-200 dark:border-zinc-800'}`}>
                            <div className="flex-1 min-w-0">
                                <div className="flex items-center gap-2 mb-1">
                                    <span className="font-semibold text-sm text-zinc-900 dark:text-zinc-100 truncate">{m.label}</span>
                                    {m.isDownloaded && m.id === activeModelId ? (
                                        // Active only makes sense for a model that exists on disk — the server pins
                                        // a default id at boot even when nothing is downloaded yet.
                                        <span className="flex-shrink-0 inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-semibold bg-purple-100 text-purple-700 dark:bg-purple-500/20 dark:text-purple-400">
                                            <CheckCircle2 className="w-2.5 h-2.5" /> Active
                                        </span>
                                    ) : m.isDownloaded && (
                                        <span className="flex-shrink-0 inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-semibold bg-emerald-100 text-emerald-700 dark:bg-emerald-500/20 dark:text-emerald-400">
                                            <CheckCircle2 className="w-2.5 h-2.5" /> Ready
                                        </span>
                                    )}
                                </div>
                                <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-zinc-500 dark:text-zinc-400">
                                    <span className="flex items-center gap-1 tabular-nums"><Zap className="w-3 h-3" />{m.paramsBillions}B params</span>
                                    <span className="flex items-center gap-1 tabular-nums"><HardDrive className="w-3 h-3" />~{m.ramGb}GB RAM</span>
                                    {fileSizeGb && <span className="tabular-nums">{fileSizeGb}GB on disk</span>}
                                    {!m.isDownloaded && <span className="text-zinc-400">{m.sizeLabel}</span>}
                                    <span className="px-1.5 py-0.5 rounded bg-zinc-100 dark:bg-zinc-800 font-mono text-[10px]">{m.quantization}</span>
                                </div>
                                {modelActionError?.id === m.id && (
                                    <p className="mt-1.5 text-[11px] text-red-600 dark:text-red-400 flex items-center gap-1">
                                        <AlertTriangle className="w-3 h-3 flex-shrink-0" /> {modelActionError.message}
                                    </p>
                                )}
                            </div>
                            <div className="flex-shrink-0 flex items-center gap-2">
                                {m.isDownloaded ? (
                                    <>
                                        {m.id !== activeModelId && (
                                            <button
                                                onClick={() => handleSwitchModel(m.id)}
                                                disabled={isActing}
                                                className="flex items-center gap-1.5 px-3 py-1.5 text-[11px] font-semibold text-purple-700 dark:text-purple-400 border border-purple-200 dark:border-purple-500/30 rounded-lg hover:bg-purple-50 dark:hover:bg-purple-500/10 transition-colors disabled:opacity-50"
                                            >
                                                {isActing && modelActionType === 'switch' ? <span className="animate-spin">⟳</span> : <Zap className="w-3 h-3" />}
                                                {isActing && modelActionType === 'switch' ? 'Switching...' : 'Use'}
                                            </button>
                                        )}
                                        <button
                                            onClick={() => handleDeleteModel(m.id)}
                                            disabled={isActing}
                                            className="flex items-center gap-1.5 px-3 py-1.5 text-[11px] font-semibold text-red-600 dark:text-red-400 border border-red-200 dark:border-red-500/30 rounded-lg hover:bg-red-50 dark:hover:bg-red-500/10 transition-colors disabled:opacity-50"
                                        >
                                            {isActing && modelActionType === 'delete' ? <span className="animate-spin">⟳</span> : <Trash2 className="w-3 h-3" />}
                                            {isActing && modelActionType === 'delete' ? 'Deleting...' : 'Delete'}
                                        </button>
                                    </>
                                ) : (
                                    <button
                                        onClick={() => handleDownloadModel(m.id)}
                                        disabled={isActing}
                                        className="flex items-center gap-1.5 px-3 py-1.5 text-[11px] font-semibold text-emerald-700 dark:text-emerald-400 border border-emerald-200 dark:border-emerald-500/30 rounded-lg hover:bg-emerald-50 dark:hover:bg-emerald-500/10 transition-colors disabled:opacity-50"
                                    >
                                        {isActing && modelActionType === 'download' ? <span className="animate-spin">⟳</span> : <Download className="w-3 h-3" />}
                                        {isActing && modelActionType === 'download' ? 'Starting...' : 'Download'}
                                    </button>
                                )}
                            </div>
                        </div>
                    );
                })}
            </div>
        </section>
    );
}
