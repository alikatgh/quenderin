import { useState, useEffect, useRef } from 'react';
import { Shield, Bell, Monitor, Moon, Sun, ArrowLeft, Save, CheckCircle2, RotateCcw, BrainCircuit, Download, Trash2, HardDrive, Zap, Cpu, FileText, Brain, ChevronDown, ChevronRight, AlertTriangle } from 'lucide-react';

interface Settings {
    contextSize: number;
    memorySafetyEnabled: boolean;
    chatLogDedupeMs: number;
    themePreference: 'light' | 'dark' | 'system';
    privacyLockEnabled: boolean;
    privacyPassphrase: string;
}

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

interface SettingsAreaProps {
    onBack: () => void;
    currentSettings: Settings;
    onSave: (newSettings: Settings) => void;
    onReset: () => void;
    onThemeChange?: (theme: 'light' | 'dark' | 'system') => void;
    /** Hardware-adaptive context sizes from /health (e.g. [256,512,1024] for Pi) */
    contextOptions?: number[];
    /** Hardware tier string from backend (for display) */
    hardwareTier?: string;
    hardwareArch?: string;
    hardwareCpuCores?: number;
    /** Last backend outage summary persisted from runtime recovery events */
    lastOutageInfo?: { seconds: number; recoveredAt: string } | null;
    /** Clears persisted outage diagnostics */
    onClearOutageHistory?: () => void;
    /** Current backend readiness stage from runtime polling */
    readinessStage?: string;
}

const CONTEXT_LABELS: Record<number, string> = {
    256: 'Minimal',
    512: 'Eco',
    1024: 'Eco',
    2048: 'Standard',
    4096: 'Power',
    8192: 'Ultra',
};

const createDiagnosticsId = (): string => {
    if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
        return crypto.randomUUID();
    }
    return `diag-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
};

const downloadDiagnosticsJson = (payload: string, diagnosticsId?: string | null): void => {
    const safeId = (diagnosticsId ?? 'unknown').replace(/[^a-zA-Z0-9-_]/g, '').slice(0, 24) || 'unknown';
    const fileName = `quenderin-diagnostics-${safeId}.json`;
    const blob = new Blob([payload], { type: 'application/json;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = fileName;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
};

export function SettingsArea({ onBack, currentSettings, onSave, onReset, onThemeChange, contextOptions, hardwareTier, hardwareArch, hardwareCpuCores, lastOutageInfo, onClearOutageHistory, readinessStage }: SettingsAreaProps) {
    const [settings, setSettings] = useState<Settings>(currentSettings);
    const [isSaved, setIsSaved] = useState(false);
    const [modelCatalog, setModelCatalog] = useState<ModelCatalogEntry[]>([]);
    const [modelActionId, setModelActionId] = useState<string | null>(null); // which model is being downloaded/deleted
    const [modelActionType, setModelActionType] = useState<'download' | 'delete' | null>(null);
    const [diagCopied, setDiagCopied] = useState(false);
    const [diagCopiedFromFallback, setDiagCopiedFromFallback] = useState(false);
    const [diagCopyFailed, setDiagCopyFailed] = useState(false);
    const [lastCopiedAt, setLastCopiedAt] = useState<Date | null>(null);
    const [lastDiagnosticsId, setLastDiagnosticsId] = useState<string | null>(null);
    const [manualDiagnosticsPayload, setManualDiagnosticsPayload] = useState<string | null>(null);
    const manualPayloadRef = useRef<HTMLTextAreaElement | null>(null);

    // Notes
    const [notes, setNotes] = useState<{ filename: string; title: string; preview: string; modifiedAt: number; sizeBytes: number }[]>([]);
    const [notesOpen, setNotesOpen] = useState(false);
    const [deletingNote, setDeletingNote] = useState<string | null>(null);

    // Agent memory
    const [trajectories, setTrajectories] = useState<{ goal: string; actionCount: number; timestamp: string }[]>([]);
    const [memoryOpen, setMemoryOpen] = useState(false);
    const [memoryTotal, setMemoryTotal] = useState(0);
    const [clearingMemory, setClearingMemory] = useState(false);

    useEffect(() => {
        if (notesOpen) {
            fetch('/api/notes').then(r => r.ok ? r.json() : null).then(d => { if (d?.notes) setNotes(d.notes); }).catch(() => {});
        }
    }, [notesOpen]);

    useEffect(() => {
        if (memoryOpen) {
            fetch('/api/memory/trajectories').then(r => r.ok ? r.json() : null).then(d => { if (d) { setTrajectories(d.trajectories); setMemoryTotal(d.total); } }).catch(() => {});
        }
    }, [memoryOpen]);

    const handleDeleteNote = async (filename: string) => {
        setDeletingNote(filename);
        await fetch(`/api/notes/${encodeURIComponent(filename)}`, { method: 'DELETE' }).catch(() => {});
        setNotes(prev => prev.filter(n => n.filename !== filename));
        setDeletingNote(null);
    };

    const handleClearMemory = async () => {
        if (!confirm('Clear all agent learned trajectories? The agent will start fresh without any prior experience.')) return;
        setClearingMemory(true);
        await fetch('/api/memory/trajectories', { method: 'DELETE' }).catch(() => {});
        setTrajectories([]);
        setMemoryTotal(0);
        setClearingMemory(false);
    };

    const shortDiagnosticsId = lastDiagnosticsId
        ? lastDiagnosticsId.replace(/[^a-zA-Z0-9]/g, '').slice(0, 8)
        : null;

    useEffect(() => {
        setSettings(currentSettings);
    }, [currentSettings]);

    useEffect(() => {
        fetch('/api/models/catalog')
            .then(r => r.json())
            .then(d => setModelCatalog(d.catalog ?? []))
            .catch(() => {});
    }, []);

    const refreshCatalog = () => {
        fetch('/api/models/catalog')
            .then(r => r.json())
            .then(d => setModelCatalog(d.catalog ?? []))
            .catch(() => {});
    };

    const handleDownloadModel = async (modelId: string) => {
        setModelActionId(modelId);
        setModelActionType('download');
        try {
            await fetch('/api/models/download', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ modelId }),
            });
        } finally {
            // Poll catalog after a short delay to pick up download status
            setTimeout(refreshCatalog, 2000);
            setModelActionId(null);
            setModelActionType(null);
        }
    };

    const handleDeleteModel = async (modelId: string) => {
        if (!confirm('Delete this model from disk? You will need to re-download it to use it again.')) return;
        setModelActionId(modelId);
        setModelActionType('delete');
        try {
            await fetch(`/api/models/${modelId}`, { method: 'DELETE' });
        } finally {
            setTimeout(refreshCatalog, 500);
            setModelActionId(null);
            setModelActionType(null);
        }
    };

    useEffect(() => {
        if (!manualDiagnosticsPayload || !manualPayloadRef.current) return;
        manualPayloadRef.current.focus();
        manualPayloadRef.current.select();
    }, [manualDiagnosticsPayload]);

    const handleSave = () => {
        onSave(settings);
        setIsSaved(true);
        setTimeout(() => setIsSaved(false), 2000);
    };

    const handleCopyDiagnostics = async () => {
        let payload = '';
        try {
            setDiagCopyFailed(false);
            const diagnosticsId = createDiagnosticsId();
            setLastDiagnosticsId(diagnosticsId);
            let serverDiagnostics: unknown = null;
            let serverDiagnosticsError: string | null = null;

            try {
                const controller = new AbortController();
                const timeout = setTimeout(() => controller.abort(), 2500);
                try {
                    const response = await fetch(`/diagnostics?historyLimit=5&diagnosticsId=${encodeURIComponent(diagnosticsId)}`, {
                        cache: 'no-store',
                        signal: controller.signal,
                        headers: {
                            'x-diagnostics-id': diagnosticsId,
                        },
                    });

                    if (!response.ok) {
                        serverDiagnosticsError = `HTTP ${response.status}`;
                    } else {
                        serverDiagnostics = await response.json();
                    }
                } finally {
                    clearTimeout(timeout);
                }
            } catch (error) {
                serverDiagnosticsError = error instanceof Error ? error.message : String(error);
            }

            const summary = {
                diagnosticsId,
                diagnosticsSchemaVersion: '1.1.0',
                capturedAt: new Date().toISOString(),
                client: {
                    readinessStage: readinessStage ?? 'unknown',
                    hardwareTier: hardwareTier ?? 'unknown',
                    contextSize: settings.contextSize,
                    memorySafetyEnabled: settings.memorySafetyEnabled,
                    lastOutage: lastOutageInfo ?? null,
                },
                server: serverDiagnostics,
                serverDiagnosticsError,
            };

            payload = JSON.stringify(summary, null, 2);
            await navigator.clipboard.writeText(payload);
            setDiagCopyFailed(false);
            setDiagCopiedFromFallback(false);
            setManualDiagnosticsPayload(null);
            setLastCopiedAt(new Date());
            setDiagCopied(true);
            setTimeout(() => setDiagCopied(false), 1800);
        } catch {
            setDiagCopied(false);
            setDiagCopyFailed(true);
            if (payload) {
                setManualDiagnosticsPayload(payload);
            }
            setTimeout(() => setDiagCopyFailed(false), 2200);
        }
    };

    const handleCopyManualDiagnostics = async () => {
        if (!manualDiagnosticsPayload) return;
        try {
            await navigator.clipboard.writeText(manualDiagnosticsPayload);
            setDiagCopyFailed(false);
            setDiagCopiedFromFallback(true);
            setManualDiagnosticsPayload(null);
            setLastCopiedAt(new Date());
            setDiagCopied(true);
            setTimeout(() => {
                setDiagCopied(false);
                setDiagCopiedFromFallback(false);
            }, 1800);
        } catch {
            setDiagCopied(false);
            setDiagCopyFailed(true);
            setTimeout(() => setDiagCopyFailed(false), 2200);
        }
    };

    return (
        <div className="flex-1 overflow-y-auto bg-[#fafafa] dark:bg-[#09090b] animate-in fade-in duration-500">
            <div className="max-w-3xl mx-auto px-6 py-12">

                {/* Header */}
                <div className="flex items-center justify-between mb-10">
                    <div className="flex items-center gap-4">
                        <button
                            onClick={onBack}
                            className="p-2 hover:bg-zinc-200 dark:hover:bg-zinc-800 rounded-full transition-colors transition-colors"
                        >
                            <ArrowLeft className="w-5 h-5 text-zinc-600 dark:text-zinc-400" />
                        </button>
                        <h1 className="text-2xl font-bold text-zinc-900 dark:text-white tracking-tight">System Settings</h1>
                    </div>
                    <div className="flex items-center gap-3">
                        <button
                            onClick={() => { onReset(); setIsSaved(false); }}
                            className="flex items-center gap-2 px-4 py-2 border border-zinc-200 dark:border-zinc-700 text-zinc-600 dark:text-zinc-400 text-sm font-semibold rounded-xl transition-all hover:bg-zinc-100 dark:hover:bg-zinc-800 active:scale-95"
                        >
                            <RotateCcw className="w-4 h-4" />
                            Reset Defaults
                        </button>
                        <button
                            onClick={handleSave}
                            className="flex items-center gap-2 px-4 py-2 bg-purple-600 hover:bg-purple-700 text-white text-sm font-semibold rounded-xl transition-all shadow-lg shadow-purple-500/10 active:scale-95"
                        >
                            {isSaved ? <CheckCircle2 className="w-4 h-4" /> : <Save className="w-4 h-4" />}
                            {isSaved ? 'Settings Applied' : 'Apply Changes'}
                        </button>
                    </div>
                </div>

                <div className="space-y-8">

                    {/* RAM Armor Section */}
                    <section className="premium-card p-6">
                        <div className="flex items-center gap-3 mb-6">
                            <div className="p-2 bg-blue-100 dark:bg-blue-500/10 text-blue-600 dark:text-blue-400 rounded-lg border border-blue-200 dark:border-blue-500/20">
                                <Shield className="w-5 h-5" />
                            </div>
                            <div>
                                <h2 className="text-lg font-bold text-zinc-900 dark:text-white">RAM Armor</h2>
                                <p className="text-sm text-zinc-500 dark:text-zinc-400">Control how much memory the AI consumes.</p>
                            </div>
                        </div>

                        <div className="space-y-6">
                            <div>
                                <label className="block text-sm font-semibold text-zinc-700 dark:text-zinc-300 mb-3">
                                    AI Context Window (RAM Usage)
                                    {hardwareTier && (
                                        <span className="ml-2 text-xs font-normal text-zinc-400 dark:text-zinc-500">
                                            — {hardwareTier} hardware detected
                                        </span>
                                    )}
                                </label>
                                <div className="grid grid-cols-3 gap-3">
                                    {(contextOptions ?? [1024, 2048, 4096]).map((size, i, arr) => {
                                        const label = i === 0 ? (CONTEXT_LABELS[size] ?? 'Low')
                                            : i === arr.length - 1 ? (CONTEXT_LABELS[size] ?? 'High')
                                            : (CONTEXT_LABELS[size] ?? 'Mid');
                                        const pct = Math.round(((i + 1) / arr.length) * 100);
                                        return (
                                        <button
                                            key={size}
                                            onClick={() => setSettings({ ...settings, contextSize: size })}
                                            className={`p-4 rounded-xl border text-left transition-all ${settings.contextSize === size
                                                ? 'bg-blue-50 dark:bg-blue-500/10 border-blue-500 text-blue-700 dark:text-blue-400 ring-2 ring-blue-500/20'
                                                : 'bg-zinc-50 dark:bg-[#18181b] border-zinc-200 dark:border-zinc-800 text-zinc-600 dark:text-zinc-400 hover:border-zinc-300 dark:hover:border-zinc-700'
                                                }`}
                                        >
                                            <div className="font-bold text-base mb-1">{label}</div>
                                            <div className="text-[11px] opacity-70 mb-2">{size} Tokens</div>
                                            <div className="w-full h-1.5 bg-zinc-200 dark:bg-zinc-800 rounded-full overflow-hidden">
                                                <div className={`h-full bg-blue-500 transition-all`} style={{ width: `${pct}%` }}></div>
                                            </div>
                                        </button>
                                        );
                                    })}
                                </div>
                                <p className="mt-3 text-[12px] text-zinc-500 dark:text-zinc-500 italic">
                                    Lower values use less RAM but may make the AI less observant in long tasks.
                                </p>
                            </div>

                            {lastOutageInfo && (
                                <div className="rounded-xl border border-amber-200 dark:border-amber-500/20 bg-amber-50 dark:bg-amber-500/10 px-4 py-3">
                                    <div className="flex items-center justify-between gap-3">
                                        <div className="text-xs font-semibold text-amber-700 dark:text-amber-300">
                                            Last backend outage: {lastOutageInfo.seconds}s
                                        </div>
                                        <div className="flex items-center gap-2">
                                            <button
                                                onClick={handleCopyDiagnostics}
                                                className="text-[11px] font-semibold px-2 py-1 rounded-md border border-amber-300/70 dark:border-amber-500/30 hover:bg-amber-100 dark:hover:bg-amber-500/20 transition-colors text-amber-700 dark:text-amber-300"
                                            >
                                                {diagCopyFailed
                                                    ? 'Copy failed • Retry'
                                                    : diagCopied
                                                        ? `${diagCopiedFromFallback ? 'Copied from fallback' : 'Copied!'} • ID: ${shortDiagnosticsId ?? 'n/a'}`
                                                        : 'Copy diagnostics'}
                                            </button>
                                            <button
                                                onClick={onClearOutageHistory}
                                                className="text-[11px] font-semibold px-2 py-1 rounded-md border border-amber-300/70 dark:border-amber-500/30 hover:bg-amber-100 dark:hover:bg-amber-500/20 transition-colors text-amber-700 dark:text-amber-300"
                                            >
                                                Clear history
                                            </button>
                                        </div>
                                    </div>
                                    <div className="text-[11px] text-amber-700/80 dark:text-amber-300/80 mt-1">
                                        Recovered at {new Date(lastOutageInfo.recoveredAt).toLocaleString()}
                                    </div>
                                    {lastCopiedAt && (
                                        <div className="text-[11px] text-amber-700/80 dark:text-amber-300/80 mt-1">
                                            Last copied at {lastCopiedAt.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}
                                        </div>
                                    )}
                                    {manualDiagnosticsPayload && (
                                        <div className="mt-3 rounded-lg border border-amber-300/60 dark:border-amber-500/30 bg-amber-100/60 dark:bg-amber-500/10 p-2.5">
                                            <div className="flex items-center justify-between gap-2 mb-2">
                                                <div className="text-[11px] font-semibold text-amber-800 dark:text-amber-200">
                                                    Clipboard unavailable — copy manually
                                                </div>
                                                <div className="flex items-center gap-1.5">
                                                    <button
                                                        onClick={handleCopyManualDiagnostics}
                                                        className="text-[10px] font-semibold px-2 py-0.5 rounded-md border border-amber-300/70 dark:border-amber-500/30 hover:bg-amber-200/60 dark:hover:bg-amber-500/20 transition-colors text-amber-700 dark:text-amber-300"
                                                    >
                                                        Copy now
                                                    </button>
                                                    <button
                                                        onClick={() => downloadDiagnosticsJson(manualDiagnosticsPayload, lastDiagnosticsId)}
                                                        className="text-[10px] font-semibold px-2 py-0.5 rounded-md border border-amber-300/70 dark:border-amber-500/30 hover:bg-amber-200/60 dark:hover:bg-amber-500/20 transition-colors text-amber-700 dark:text-amber-300"
                                                    >
                                                        Download .json
                                                    </button>
                                                    <button
                                                        onClick={() => setManualDiagnosticsPayload(null)}
                                                        className="text-[10px] font-semibold px-2 py-0.5 rounded-md border border-amber-300/70 dark:border-amber-500/30 hover:bg-amber-200/60 dark:hover:bg-amber-500/20 transition-colors text-amber-700 dark:text-amber-300"
                                                    >
                                                        Hide
                                                    </button>
                                                </div>
                                            </div>
                                            <textarea
                                                ref={manualPayloadRef}
                                                readOnly
                                                value={manualDiagnosticsPayload}
                                                onFocus={(e) => e.currentTarget.select()}
                                                className="w-full h-28 text-[10px] leading-4 font-mono rounded-md border border-amber-300/70 dark:border-amber-500/30 bg-amber-50 dark:bg-[#09090b] text-amber-900 dark:text-amber-100 p-2 outline-none"
                                            />
                                        </div>
                                    )}
                                </div>
                            )}

                            <div className="flex items-center justify-between py-4 border-t border-zinc-100 dark:border-zinc-800/50">
                                <div className="flex items-center gap-3">
                                    <Bell className="w-4 h-4 text-zinc-400" />
                                    <div>
                                        <div className="text-sm font-semibold text-zinc-700 dark:text-zinc-300">Memory Safety Warnings</div>
                                        <div className="text-xs text-zinc-500 dark:text-zinc-500">Warn me when system RAM is dangerously low.</div>
                                    </div>
                                </div>
                                <button
                                    onClick={() => setSettings({ ...settings, memorySafetyEnabled: !settings.memorySafetyEnabled })}
                                    className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${settings.memorySafetyEnabled ? 'bg-purple-600' : 'bg-zinc-300 dark:bg-zinc-700'}`}
                                >
                                    <span className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${settings.memorySafetyEnabled ? 'translate-x-6' : 'translate-x-1'}`} />
                                </button>
                            </div>

                            <div className="pt-2 border-t border-zinc-100 dark:border-zinc-800/50">
                                <label className="block text-sm font-semibold text-zinc-700 dark:text-zinc-300 mb-3">Duplicate Chat Bubble Suppression</label>
                                <div className="grid grid-cols-4 gap-3">
                                    {[0, 500, 1000, 2000].map((ms) => (
                                        <button
                                            key={ms}
                                            onClick={() => setSettings({ ...settings, chatLogDedupeMs: ms })}
                                            className={`p-3 rounded-xl border text-center transition-all ${settings.chatLogDedupeMs === ms
                                                ? 'bg-blue-50 dark:bg-blue-500/10 border-blue-500 text-blue-700 dark:text-blue-400 ring-2 ring-blue-500/20'
                                                : 'bg-zinc-50 dark:bg-[#18181b] border-zinc-200 dark:border-zinc-800 text-zinc-600 dark:text-zinc-400 hover:border-zinc-300 dark:hover:border-zinc-700'
                                                }`}
                                        >
                                            <div className="font-bold text-sm">{ms}ms</div>
                                        </button>
                                    ))}
                                </div>
                                <p className="mt-3 text-[12px] text-zinc-500 dark:text-zinc-500 italic">
                                    Hides repeated identical user bubbles sent too quickly. Set to 0ms to disable suppression.
                                </p>
                            </div>
                        </div>
                    </section>

                    {/* Privacy Section */}
                    <section className="premium-card p-6">
                        <div className="flex items-center gap-3 mb-6">
                            <div className="p-2 bg-red-100 dark:bg-red-500/10 text-red-600 dark:text-red-400 rounded-lg border border-red-200 dark:border-red-500/20">
                                <Shield className="w-5 h-5" />
                            </div>
                            <div>
                                <h2 className="text-lg font-bold text-zinc-900 dark:text-white">Privacy Lock</h2>
                                <p className="text-sm text-zinc-500 dark:text-zinc-400">Secure your local AI assistant with a passphrase.</p>
                            </div>
                        </div>

                        <div className="space-y-6">
                            <div className="flex items-center justify-between">
                                <div className="text-sm font-semibold text-zinc-700 dark:text-zinc-300">Enable Application Lock</div>
                                <button
                                    onClick={() => setSettings({ ...settings, privacyLockEnabled: !settings.privacyLockEnabled })}
                                    className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${settings.privacyLockEnabled ? 'bg-purple-600' : 'bg-zinc-300 dark:bg-zinc-700'}`}
                                >
                                    <span className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${settings.privacyLockEnabled ? 'translate-x-6' : 'translate-x-1'}`} />
                                </button>
                            </div>

                            {settings.privacyLockEnabled && (
                                <div className="animate-in fade-in slide-in-from-top-2 duration-300">
                                    <label className="block text-sm font-semibold text-zinc-700 dark:text-zinc-300 mb-2">Passphrase</label>
                                    <input
                                        type="password"
                                        value={settings.privacyPassphrase}
                                        onChange={(e) => setSettings({ ...settings, privacyPassphrase: e.target.value })}
                                        placeholder="Enter passphrase"
                                        className="w-full bg-zinc-50 dark:bg-[#09090b] border border-zinc-200 dark:border-zinc-800 focus:border-purple-500 focus:ring-2 focus:ring-purple-500/20 rounded-xl py-2 px-4 shadow-inner outline-none transition-all"
                                    />
                                    <p className="mt-2 text-[12px] text-red-500 font-medium">Warning: If lost, local conversation history cannot be un-encrypted.</p>
                                </div>
                            )}
                        </div>
                    </section>

                    {/* Appearance Section */}
                    <section className="premium-card p-6">
                        <div className="flex items-center gap-3 mb-6">
                            <div className="p-2 bg-purple-100 dark:bg-purple-500/10 text-purple-600 dark:text-purple-400 rounded-lg border border-purple-200 dark:border-purple-500/20">
                                <Sun className="w-5 h-5 dark:hidden" />
                                <Moon className="w-5 h-5 hidden dark:block" />
                            </div>
                            <div>
                                <h2 className="text-lg font-bold text-zinc-900 dark:text-white">Appearance</h2>
                                <p className="text-sm text-zinc-500 dark:text-zinc-400">Humidify your visual experience.</p>
                            </div>
                        </div>

                        <div className="grid grid-cols-3 gap-3">
                            {[
                                { id: 'light', label: 'Light Mode', icon: Sun },
                                { id: 'dark', label: 'Dark Mode', icon: Moon },
                                { id: 'system', label: 'System', icon: Monitor }
                            ].map((mode) => (
                                <button
                                    key={mode.id}
                                    onClick={() => {
                                        const pref = mode.id as 'light' | 'dark' | 'system';
                                        setSettings({ ...settings, themePreference: pref });
                                        onThemeChange?.(pref);
                                    }}
                                    className={`p-4 rounded-xl border flex flex-col items-center gap-2 transition-all ${settings.themePreference === mode.id
                                        ? 'bg-purple-50 dark:bg-purple-500/10 border-purple-500 text-purple-700 dark:text-purple-400 ring-2 ring-purple-500/20'
                                        : 'bg-zinc-50 dark:bg-[#18181b] border-zinc-200 dark:border-zinc-800 text-zinc-600 dark:text-zinc-400 hover:border-zinc-300 dark:hover:border-zinc-700'
                                        }`}
                                >
                                    <mode.icon className="w-5 h-5 mb-1" />
                                    <span className="text-xs font-semibold">{mode.label}</span>
                                </button>
                            ))}
                        </div>
                    </section>
                </div>

                    {/* Model Manager Section */}
                    <section className="premium-card p-6">
                        <div className="flex items-center gap-3 mb-6">
                            <div className="p-2 bg-emerald-100 dark:bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 rounded-lg border border-emerald-200 dark:border-emerald-500/20">
                                <BrainCircuit className="w-5 h-5" />
                            </div>
                            <div>
                                <h2 className="text-lg font-bold text-zinc-900 dark:text-white">AI Model Manager</h2>
                                <p className="text-sm text-zinc-500 dark:text-zinc-400">Download or remove local AI models. All inference is 100% offline.</p>
                            </div>
                        </div>

                        <div className="space-y-3">
                            {modelCatalog.length === 0 ? (
                                <div className="text-sm text-zinc-500 dark:text-zinc-400 text-center py-4">Loading models...</div>
                            ) : modelCatalog.map(m => {
                                const fileSizeGb = m.fileSizeBytes > 0 ? (m.fileSizeBytes / (1024 ** 3)).toFixed(2) : null;
                                const isActing = modelActionId === m.id;
                                return (
                                    <div key={m.id} className={`flex items-center gap-4 p-4 rounded-xl border transition-all ${m.isDownloaded ? 'bg-emerald-50/50 dark:bg-emerald-900/10 border-emerald-200 dark:border-emerald-500/20' : 'bg-zinc-50 dark:bg-[#18181b] border-zinc-200 dark:border-zinc-800'}`}>
                                        <div className="flex-1 min-w-0">
                                            <div className="flex items-center gap-2 mb-1">
                                                <span className="font-semibold text-sm text-zinc-900 dark:text-zinc-100 truncate">{m.label}</span>
                                                {m.isDownloaded && (
                                                    <span className="flex-shrink-0 inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-bold bg-emerald-100 text-emerald-700 dark:bg-emerald-500/20 dark:text-emerald-400">
                                                        <CheckCircle2 className="w-2.5 h-2.5" /> Ready
                                                    </span>
                                                )}
                                            </div>
                                            <div className="flex items-center gap-3 text-[11px] text-zinc-500 dark:text-zinc-400">
                                                <span className="flex items-center gap-1"><Zap className="w-3 h-3" />{m.paramsBillions}B params</span>
                                                <span className="flex items-center gap-1"><HardDrive className="w-3 h-3" />~{m.ramGb}GB RAM</span>
                                                {fileSizeGb && <span>{fileSizeGb}GB on disk</span>}
                                                {!m.isDownloaded && <span className="text-zinc-400">{m.sizeLabel}</span>}
                                                <span className="px-1.5 py-0.5 rounded bg-zinc-100 dark:bg-zinc-800 font-mono text-[10px]">{m.quantization}</span>
                                            </div>
                                        </div>
                                        <div className="flex-shrink-0">
                                            {m.isDownloaded ? (
                                                <button
                                                    onClick={() => handleDeleteModel(m.id)}
                                                    disabled={isActing}
                                                    className="flex items-center gap-1.5 px-3 py-1.5 text-[11px] font-semibold text-red-600 dark:text-red-400 border border-red-200 dark:border-red-500/30 rounded-lg hover:bg-red-50 dark:hover:bg-red-500/10 transition-colors disabled:opacity-50"
                                                >
                                                    {isActing && modelActionType === 'delete' ? <span className="animate-spin">⟳</span> : <Trash2 className="w-3 h-3" />}
                                                    {isActing && modelActionType === 'delete' ? 'Deleting...' : 'Delete'}
                                                </button>
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

                    {/* Hardware Info Section */}
                    {(hardwareTier || hardwareArch || hardwareCpuCores) && (
                        <section className="premium-card p-6">
                            <div className="flex items-center gap-3 mb-5">
                                <div className="p-2 bg-orange-100 dark:bg-orange-500/10 text-orange-600 dark:text-orange-400 rounded-lg border border-orange-200 dark:border-orange-500/20">
                                    <Cpu className="w-5 h-5" />
                                </div>
                                <div>
                                    <h2 className="text-lg font-bold text-zinc-900 dark:text-white">Hardware Profile</h2>
                                    <p className="text-sm text-zinc-500 dark:text-zinc-400">Quenderin auto-tunes to your hardware for best performance.</p>
                                </div>
                            </div>
                            <div className="grid grid-cols-3 gap-3">
                                {hardwareTier && (
                                    <div className="bg-zinc-50 dark:bg-[#18181b] border border-zinc-200 dark:border-zinc-800 rounded-xl p-4 text-center">
                                        <div className="text-[11px] font-bold uppercase tracking-widest text-zinc-400 dark:text-zinc-500 mb-1">Tier</div>
                                        <div className={`text-sm font-bold capitalize ${hardwareTier === 'powerful' ? 'text-emerald-600 dark:text-emerald-400' : hardwareTier === 'standard' ? 'text-blue-600 dark:text-blue-400' : hardwareTier === 'constrained' ? 'text-amber-600 dark:text-amber-400' : 'text-red-600 dark:text-red-400'}`}>{hardwareTier}</div>
                                    </div>
                                )}
                                {hardwareArch && (
                                    <div className="bg-zinc-50 dark:bg-[#18181b] border border-zinc-200 dark:border-zinc-800 rounded-xl p-4 text-center">
                                        <div className="text-[11px] font-bold uppercase tracking-widest text-zinc-400 dark:text-zinc-500 mb-1">CPU Arch</div>
                                        <div className="text-sm font-bold text-zinc-900 dark:text-zinc-100 font-mono">{hardwareArch}</div>
                                    </div>
                                )}
                                {hardwareCpuCores && (
                                    <div className="bg-zinc-50 dark:bg-[#18181b] border border-zinc-200 dark:border-zinc-800 rounded-xl p-4 text-center">
                                        <div className="text-[11px] font-bold uppercase tracking-widest text-zinc-400 dark:text-zinc-500 mb-1">CPU Cores</div>
                                        <div className="text-sm font-bold text-zinc-900 dark:text-zinc-100">{hardwareCpuCores}</div>
                                    </div>
                                )}
                            </div>
                        </section>
                    )}

                    {/* Notes Panel */}
                    <section className="premium-card p-6">
                        <button
                            onClick={() => setNotesOpen(o => !o)}
                            className="w-full flex items-center justify-between"
                        >
                            <div className="flex items-center gap-3">
                                <div className="p-2 bg-blue-100 dark:bg-blue-500/10 text-blue-600 dark:text-blue-400 rounded-lg border border-blue-200 dark:border-blue-500/20">
                                    <FileText className="w-5 h-5" />
                                </div>
                                <div className="text-left">
                                    <h2 className="text-lg font-bold text-zinc-900 dark:text-white">Saved Notes</h2>
                                    <p className="text-sm text-zinc-500 dark:text-zinc-400">Notes written by the AI using the note_save tool.</p>
                                </div>
                            </div>
                            {notesOpen ? <ChevronDown className="w-4 h-4 text-zinc-400" /> : <ChevronRight className="w-4 h-4 text-zinc-400" />}
                        </button>
                        {notesOpen && (
                            <div className="mt-5">
                                {notes.length === 0 ? (
                                    <p className="text-sm text-zinc-500 dark:text-zinc-400 text-center py-6">No notes saved yet. Ask the AI to "save a note about..."</p>
                                ) : (
                                    <div className="space-y-2">
                                        {notes.map(note => (
                                            <div key={note.filename} className="flex items-start justify-between gap-3 p-3 rounded-xl bg-zinc-50 dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800">
                                                <div className="min-w-0 flex-1">
                                                    <p className="text-[13px] font-semibold text-zinc-900 dark:text-zinc-100 truncate">{note.title}</p>
                                                    <p className="text-[11px] text-zinc-500 dark:text-zinc-400 mt-0.5 line-clamp-2">{note.preview}</p>
                                                    <p className="text-[10px] text-zinc-400 dark:text-zinc-500 mt-1">{new Date(note.modifiedAt).toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' })} · {(note.sizeBytes / 1024).toFixed(1)} KB</p>
                                                </div>
                                                <button
                                                    onClick={() => handleDeleteNote(note.filename)}
                                                    disabled={deletingNote === note.filename}
                                                    className="flex-shrink-0 p-1.5 text-red-500 hover:bg-red-50 dark:hover:bg-red-500/10 rounded-lg transition-colors disabled:opacity-40"
                                                >
                                                    <Trash2 className="w-3.5 h-3.5" />
                                                </button>
                                            </div>
                                        ))}
                                    </div>
                                )}
                            </div>
                        )}
                    </section>

                    {/* Agent Memory Panel */}
                    <section className="premium-card p-6">
                        <button
                            onClick={() => setMemoryOpen(o => !o)}
                            className="w-full flex items-center justify-between"
                        >
                            <div className="flex items-center gap-3">
                                <div className="p-2 bg-purple-100 dark:bg-purple-500/10 text-purple-600 dark:text-purple-400 rounded-lg border border-purple-200 dark:border-purple-500/20">
                                    <Brain className="w-5 h-5" />
                                </div>
                                <div className="text-left">
                                    <h2 className="text-lg font-bold text-zinc-900 dark:text-white">Agent Memory</h2>
                                    <p className="text-sm text-zinc-500 dark:text-zinc-400">Goals the spatial agent has learned to complete successfully.</p>
                                </div>
                            </div>
                            {memoryOpen ? <ChevronDown className="w-4 h-4 text-zinc-400" /> : <ChevronRight className="w-4 h-4 text-zinc-400" />}
                        </button>
                        {memoryOpen && (
                            <div className="mt-5">
                                <div className="flex items-center justify-between mb-3">
                                    <p className="text-[12px] text-zinc-500 dark:text-zinc-400">{memoryTotal} total trajectories stored</p>
                                    {memoryTotal > 0 && (
                                        <button
                                            onClick={handleClearMemory}
                                            disabled={clearingMemory}
                                            className="flex items-center gap-1.5 px-3 py-1.5 text-[11px] font-semibold text-red-600 dark:text-red-400 border border-red-200 dark:border-red-500/30 rounded-lg hover:bg-red-50 dark:hover:bg-red-500/10 transition-colors disabled:opacity-50"
                                        >
                                            <AlertTriangle className="w-3 h-3" />
                                            {clearingMemory ? 'Clearing...' : 'Clear All'}
                                        </button>
                                    )}
                                </div>
                                {trajectories.length === 0 ? (
                                    <p className="text-sm text-zinc-500 dark:text-zinc-400 text-center py-6">No learned trajectories yet. Run the spatial agent to build experience.</p>
                                ) : (
                                    <div className="space-y-2">
                                        {trajectories.map((t, i) => (
                                            <div key={i} className="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800">
                                                <p className="text-[13px] font-medium text-zinc-800 dark:text-zinc-200 leading-snug">{t.goal}</p>
                                                <p className="text-[10px] text-zinc-400 dark:text-zinc-500 mt-1">{t.actionCount} actions · {new Date(t.timestamp).toLocaleDateString([], { month: 'short', day: 'numeric' })}</p>
                                            </div>
                                        ))}
                                    </div>
                                )}
                            </div>
                        )}
                    </section>

                <div className="mt-12 pt-8 border-t border-zinc-200 dark:border-zinc-800/50 flex flex-col items-center text-center">
                    <div className="text-xs text-zinc-500 dark:text-zinc-500 space-y-2">
                        <p>© 2026 Quenderin Agent • Version 0.0.1</p>
                        <p>Settings are saved to your browser and applied to the local AI engine.</p>
                    </div>
                </div>
            </div>
        </div>
    );
}
