import { useState } from 'react';
import { Smartphone, Settings, CheckCircle2, AlertTriangle, BrainCircuit, Download, RefreshCw, X, AlertCircle, Monitor, Cpu } from 'lucide-react';
import type { ModelOption } from '../types/index.js';

interface TroubleshooterPayload {
    code: string;
    title: string;
    message: string;
    autoTrigger?: string | null;
    fittingModels?: ModelOption[];
    downloadedModels?: ModelOption[];
    allModels?: ModelOption[];
}

interface TroubleshooterGuideProps {
    action: TroubleshooterPayload | null;
    onResolved: () => void;
    onTriggerDownload: (modelId?: string) => void;
    downloadProgress?: number;
    recommendedModelId?: string;
}

export function TroubleshooterGuide({ action, onResolved, onTriggerDownload, downloadProgress = 0, recommendedModelId }: TroubleshooterGuideProps) {
    const [downloadingModelId, setDownloadingModelId] = useState<string | null>(null);

    if (!action) return null;

    const safeDefaultModel = recommendedModelId ?? 'llama32-1b';

    const handleDownload = (modelId?: string) => {
        setDownloadingModelId(modelId ?? safeDefaultModel);
        onTriggerDownload(modelId);
    };

    const ramColor = (gb: number) =>
        gb <= 1.5 ? 'text-emerald-600 dark:text-emerald-400 bg-emerald-100 dark:bg-emerald-500/10 border-emerald-200 dark:border-emerald-500/20'
        : gb <= 3.5 ? 'text-amber-600 dark:text-amber-400 bg-amber-100 dark:bg-amber-500/10 border-amber-200 dark:border-amber-500/20'
        : 'text-red-600 dark:text-red-400 bg-red-100 dark:bg-red-500/10 border-red-200 dark:border-red-500/20';

    const renderAdbMissing = () => (
        <div className="p-6">
            <div className="w-12 h-12 bg-emerald-100 dark:bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 rounded-xl flex items-center justify-center mb-5 border border-emerald-200 dark:border-emerald-500/20 shadow-sm">
                <Smartphone className="w-6 h-6" />
            </div>
            <h2 className="text-xl font-bold text-zinc-900 dark:text-white mb-2">Mobile Device Link Not Found</h2>
            <p className="text-zinc-600 dark:text-zinc-400 text-sm leading-relaxed mb-6">
                Ensure your virtual phone or mobile device is active. Let's fix this in 3 quick steps:
            </p>

            <div className="space-y-4 mb-8">
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><Smartphone className="w-4 h-4 text-emerald-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">1. Open Your Virtual Phone</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">If you use a simulator (like BlueStacks), please make sure it's open on your computer.</p>
                    </div>
                </div>
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><Settings className="w-4 h-4 text-emerald-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">2. Enable Mobile Link</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">Inside your virtual phone settings, ensure "Mobile Debugging" or "Device Link" is turned ON.</p>
                    </div>
                </div>
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><CheckCircle2 className="w-4 h-4 text-emerald-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">3. Verify Connection</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">Keep the emulator open and click the Retry button below to connect.</p>
                    </div>
                </div>
            </div>

            <button
                onClick={onResolved}
                className="w-full bg-emerald-600 hover:bg-emerald-700 text-white font-semibold py-2.5 px-4 rounded-xl transition-colors flex items-center justify-center gap-2"
            >
                Retry Connection
            </button>
        </div>
    );

    const renderModelMissing = () => {
        const models: ModelOption[] = action.fittingModels ?? [
            { id: 'llama32-1b', label: 'Llama 3.2 1B (Light)', ramGb: 1.5, sizeLabel: '0.8 GB' },
            { id: 'llama32-3b', label: 'Llama 3.2 3B (Balanced)', ramGb: 3.0, sizeLabel: '2.0 GB' },
            { id: 'llama3-8b', label: 'Llama 3 8B (Best Quality)', ramGb: 6.75, sizeLabel: '4.7 GB' },
        ];
        const activeId = downloadingModelId;

        return (
            <div className="p-6">
                <div className="w-12 h-12 bg-purple-100 dark:bg-purple-500/10 text-purple-600 dark:text-purple-400 rounded-xl flex items-center justify-center mb-5 border border-purple-200 dark:border-purple-500/20 shadow-sm">
                    <BrainCircuit className="w-6 h-6" />
                </div>
                <h2 className="text-xl font-bold text-zinc-900 dark:text-white mb-2">Choose an AI Model</h2>
                <p className="text-zinc-500 dark:text-zinc-400 text-sm leading-relaxed mb-6">
                    Quenderin runs 100% offline. Pick a model based on how much RAM your computer has.
                </p>

                {downloadProgress > 0 && downloadProgress < 100 && (
                    <div className="mb-6 bg-zinc-50 dark:bg-zinc-800/50 p-4 rounded-xl border border-zinc-200 dark:border-zinc-700/50">
                        <div className="flex justify-between text-xs font-semibold mb-2">
                            <span className="text-purple-600 dark:text-purple-400">Downloading {models.find(m => m.id === activeId)?.label ?? 'model'}...</span>
                            <span className="text-zinc-500">{downloadProgress}%</span>
                        </div>
                        <div className="w-full bg-zinc-200 dark:bg-zinc-700 rounded-full h-2 overflow-hidden">
                            <div className="bg-purple-500 h-2 transition-all duration-300" style={{ width: `${downloadProgress}%` }} />
                        </div>
                    </div>
                )}

                {downloadProgress === 100 ? (
                    <div className="mb-6 bg-emerald-50 dark:bg-emerald-900/20 border border-emerald-200 dark:border-emerald-500/30 rounded-xl p-4 flex items-start gap-3">
                        <CheckCircle2 className="w-5 h-5 text-emerald-500 shrink-0 mt-0.5" />
                        <div>
                            <p className="text-sm font-semibold text-emerald-900 dark:text-emerald-300">Model Installed</p>
                            <p className="text-xs text-emerald-700 dark:text-emerald-400 mt-1">Your AI assistant is ready.</p>
                        </div>
                    </div>
                ) : (
                    <div className="space-y-3 mb-6">
                        {models.map(m => (
                            <div key={m.id} className="flex items-center gap-3 p-4 rounded-xl border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900/40 hover:border-zinc-300 dark:hover:border-zinc-700 transition-all">
                                <Cpu className="w-5 h-5 text-zinc-400 flex-shrink-0" />
                                <div className="flex-1 min-w-0">
                                    <div className="flex items-center gap-2 flex-wrap">
                                        <span className="text-sm font-semibold text-zinc-900 dark:text-zinc-100 truncate">{m.label}</span>
                                        <span className={`text-[10px] font-bold px-2 py-0.5 rounded-full border ${ramColor(m.ramGb)}`}>{m.ramGb}GB RAM</span>
                                    </div>
                                    <span className="text-xs text-zinc-500">{m.sizeLabel} download</span>
                                </div>
                                <button
                                    onClick={() => handleDownload(m.id)}
                                    disabled={downloadProgress > 0}
                                    className="flex-shrink-0 flex items-center gap-1.5 px-3 py-1.5 bg-zinc-900 dark:bg-white text-white dark:text-zinc-900 text-xs font-bold rounded-lg hover:opacity-90 transition-all disabled:opacity-40 disabled:cursor-not-allowed"
                                >
                                    <Download className="w-3.5 h-3.5" />
                                    Get
                                </button>
                            </div>
                        ))}
                    </div>
                )}

                {downloadProgress === 100 && (
                    <button onClick={() => window.location.reload()} className="w-full bg-emerald-600 hover:bg-emerald-700 text-white font-semibold py-2.5 px-4 rounded-xl transition-colors flex items-center justify-center gap-2 shadow-sm">
                        <RefreshCw className="w-4 h-4" /> Start Using AI
                    </button>
                )}
                <button onClick={onResolved} className="w-full mt-3 text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 font-medium py-2 rounded-xl transition-colors text-sm">
                    Dismiss
                </button>
            </div>
        );
    };

    const renderDesktopPermissions = () => (
        <div className="p-6">
            <div className="w-12 h-12 bg-emerald-100 dark:bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 rounded-xl flex items-center justify-center mb-5 border border-emerald-200 dark:border-emerald-500/20 shadow-sm">
                <Monitor className="w-6 h-6" />
            </div>
            <h2 className="text-xl font-bold text-zinc-900 dark:text-white mb-2">{action.title}</h2>
            <p className="text-zinc-600 dark:text-zinc-400 text-sm leading-relaxed mb-6">
                {action.message} Let's enable screen recording:
            </p>

            <div className="space-y-4 mb-8">
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><Settings className="w-4 h-4 text-emerald-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">1. Open OS Settings</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">Navigate to System Settings &gt; Privacy &amp; Security.</p>
                    </div>
                </div>
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><Monitor className="w-4 h-4 text-emerald-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">2. Screen Recording</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">Select "Screen Recording" or "Screen &amp; System Audio Recording".</p>
                    </div>
                </div>
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><CheckCircle2 className="w-4 h-4 text-emerald-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">3. Enable Quenderin</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">Toggle the switch ON for Quenderin. You may need to restart the app.</p>
                    </div>
                </div>
            </div>

            <button
                onClick={onResolved}
                className="w-full bg-emerald-600 hover:bg-emerald-700 text-white font-semibold py-2.5 px-4 rounded-xl transition-colors flex items-center justify-center gap-2"
            >
                Retry Connection
            </button>
        </div>
    );

    const renderVoiceSetup = () => (
        <div className="p-6">
            <div className="w-12 h-12 bg-emerald-100 dark:bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 rounded-xl flex items-center justify-center mb-5 border border-emerald-200 dark:border-emerald-500/20 shadow-sm">
                <AlertCircle className="w-6 h-6" />
            </div>
            <h2 className="text-xl font-bold text-zinc-900 dark:text-white mb-2">{action.title || 'Voice Setup Required'}</h2>
            <p className="text-zinc-600 dark:text-zinc-400 text-sm leading-relaxed mb-6">
                {action.message || 'Voice control is optional and currently unavailable. Text chat and agent controls still work.'}
            </p>

            <div className="space-y-4 mb-8">
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><Settings className="w-4 h-4 text-emerald-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">1. Optional: Configure Voice Key</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">Set the <code>PICOVOICE_ACCESS_KEY</code> environment variable before launching Quenderin.</p>
                    </div>
                </div>
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><CheckCircle2 className="w-4 h-4 text-emerald-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">2. Continue Without Voice</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">You can dismiss this and continue using text input normally.</p>
                    </div>
                </div>
            </div>

            <button
                onClick={onResolved}
                className="w-full bg-emerald-600 hover:bg-emerald-700 text-white font-semibold py-2.5 px-4 rounded-xl transition-colors flex items-center justify-center gap-2"
            >
                Continue
            </button>
        </div>
    );

    const renderMemoryPressure = () => {
        const allModels: ModelOption[] = action.allModels ?? [
            { id: 'llama32-1b', label: 'Llama 3.2 1B (Light)', ramGb: 1.5, sizeLabel: '0.8 GB' },
            { id: 'llama32-3b', label: 'Llama 3.2 3B (Balanced)', ramGb: 3.0, sizeLabel: '2.0 GB' },
            { id: 'llama3-8b', label: 'Llama 3 8B (Best Quality)', ramGb: 6.75, sizeLabel: '4.7 GB' },
        ];
        const activeId = downloadingModelId;

        return (
            <div className="p-6">
                <div className="w-12 h-12 bg-amber-100 dark:bg-amber-500/10 text-amber-600 dark:text-amber-400 rounded-xl flex items-center justify-center mb-5 border border-amber-200 dark:border-amber-500/20 shadow-sm">
                    <AlertTriangle className="w-6 h-6" />
                </div>
                <h2 className="text-xl font-bold text-zinc-900 dark:text-white mb-2">{action.title || 'Not Enough Free RAM'}</h2>
                <p className="text-zinc-600 dark:text-zinc-400 text-sm leading-relaxed mb-6">
                    {action.message || 'Your current model is too large for available RAM.'} Try a smaller model below — it will use significantly less memory.
                </p>

                {downloadProgress > 0 && downloadProgress < 100 && (
                    <div className="mb-6 bg-zinc-50 dark:bg-zinc-800/50 p-4 rounded-xl border border-zinc-200 dark:border-zinc-700/50">
                        <div className="flex justify-between text-xs font-semibold mb-2">
                            <span className="text-amber-600 dark:text-amber-400">Downloading {allModels.find(m => m.id === activeId)?.label ?? 'model'}...</span>
                            <span className="text-zinc-500">{downloadProgress}%</span>
                        </div>
                        <div className="w-full bg-zinc-200 dark:bg-zinc-700 rounded-full h-2 overflow-hidden">
                            <div className="bg-amber-500 h-2 transition-all duration-300" style={{ width: `${downloadProgress}%` }} />
                        </div>
                    </div>
                )}

                <div className="space-y-3 mb-6">
                    {allModels.map(m => {
                        const isDownloaded = (action.downloadedModels ?? []).some((d: ModelOption) => d.id === m.id);
                        return (
                            <div key={m.id} className={`flex items-center gap-3 p-4 rounded-xl border transition-all ${
                                isDownloaded ? 'border-emerald-200 dark:border-emerald-500/30 bg-emerald-50/50 dark:bg-emerald-500/5' : 'border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900/40 hover:border-zinc-300 dark:hover:border-zinc-700'
                            }`}>
                                <Cpu className="w-5 h-5 text-zinc-400 flex-shrink-0" />
                                <div className="flex-1 min-w-0">
                                    <div className="flex items-center gap-2 flex-wrap">
                                        <span className="text-sm font-semibold text-zinc-900 dark:text-zinc-100 truncate">{m.label}</span>
                                        <span className={`text-[10px] font-bold px-2 py-0.5 rounded-full border ${ramColor(m.ramGb)}`}>{m.ramGb}GB RAM</span>
                                        {isDownloaded && <span className="text-[10px] font-bold text-emerald-600 dark:text-emerald-400">✓ installed</span>}
                                    </div>
                                    <span className="text-xs text-zinc-500">{m.sizeLabel} download</span>
                                </div>
                                {!isDownloaded ? (
                                    <button
                                        onClick={() => handleDownload(m.id)}
                                        disabled={downloadProgress > 0}
                                        className="flex-shrink-0 flex items-center gap-1.5 px-3 py-1.5 bg-zinc-900 dark:bg-white text-white dark:text-zinc-900 text-xs font-bold rounded-lg hover:opacity-90 transition-all disabled:opacity-40 disabled:cursor-not-allowed"
                                    >
                                        <Download className="w-3.5 h-3.5" />
                                        Get
                                    </button>
                                ) : (
                                    <button
                                        onClick={onResolved}
                                        className="flex-shrink-0 flex items-center gap-1.5 px-3 py-1.5 bg-emerald-600 hover:bg-emerald-700 text-white text-xs font-bold rounded-lg transition-all"
                                    >
                                        Use This
                                    </button>
                                )}
                            </div>
                        );
                    })}
                </div>

                <button onClick={onResolved} className="w-full text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 font-medium py-2 rounded-xl transition-colors text-sm">
                    Dismiss
                </button>
            </div>
        );
    };

    const renderGeneric = () => (
        <div className="p-6">
            <div className="w-12 h-12 bg-amber-100 dark:bg-amber-500/10 text-amber-600 dark:text-amber-400 rounded-xl flex items-center justify-center mb-5 border border-amber-200 dark:border-amber-500/20 shadow-sm">
                <AlertTriangle className="w-6 h-6" />
            </div>
            <h2 className="text-xl font-bold text-zinc-900 dark:text-white mb-2">{action.title || 'System Reset Required'}</h2>
            <p className="text-zinc-600 dark:text-zinc-400 text-sm leading-relaxed mb-6">
                {action.message || "Quenderin has encountered an unknown hurdle. Let's restart the system:"}
            </p>
            <div className="space-y-4 mb-8">
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><AlertTriangle className="w-4 h-4 text-amber-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">1. Restart the App on Device</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">Force close the app you are testing and reopen it.</p>
                    </div>
                </div>
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><RefreshCw className="w-4 h-4 text-amber-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">2. Reset Quenderin System</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">Click the "Restart System" button below to clear any confusion.</p>
                    </div>
                </div>
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><CheckCircle2 className="w-4 h-4 text-amber-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">3. Verify Connection</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">Ensure the device is unlocked and on a stable screen.</p>
                    </div>
                </div>
            </div>
            <button onClick={() => window.location.reload()} className="w-full bg-amber-600 hover:bg-amber-700 text-white font-semibold py-2.5 px-4 rounded-xl transition-colors flex items-center justify-center gap-2 shadow-sm">
                <RefreshCw className="w-4 h-4" /> Restart System
            </button>
            <button onClick={onResolved} className="w-full mt-3 text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 font-medium py-2 rounded-xl transition-colors text-sm">
                Dismiss
            </button>
        </div>
    );

    return (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-zinc-900/40 dark:bg-black/60 backdrop-blur-md animate-in fade-in duration-200">
            <div className="bg-white dark:bg-[#18181b] w-full max-w-lg rounded-2xl shadow-2xl border border-zinc-200 dark:border-zinc-800 overflow-hidden flex flex-col">

                {/* Header */}
                <div className="px-6 py-4 border-b border-zinc-100 dark:border-zinc-800 flex items-center justify-between bg-zinc-50/50 dark:bg-[#18181b]">
                    <div className="flex items-center gap-3">
                        <div className="p-2 bg-emerald-100 dark:bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 rounded-lg">
                            <AlertCircle className="w-5 h-5" />
                        </div>
                        <h3 className="font-semibold text-zinc-900 dark:text-zinc-100">
                            Action Required
                        </h3>
                    </div>

                    <button
                        onClick={onResolved}
                        className="p-2 text-zinc-400 hover:text-zinc-600 hover:bg-zinc-100 dark:hover:bg-zinc-800 dark:hover:text-zinc-300 rounded-full transition-colors"
                    >
                        <X className="w-5 h-5" />
                    </button>
                </div>

                <div className="overflow-y-auto max-h-[80vh]">
                    {(() => {
                        switch (action.code) {
                            case 'ADB_MISSING':
                            case 'ADB_UNAUTHORIZED':
                                return renderAdbMissing();
                            case 'DESKTOP_PERMISSIONS':
                                return renderDesktopPermissions();
                            case 'MODEL_MISSING':
                                return renderModelMissing();
                            case 'OOM_PREVENTION':
                                return renderMemoryPressure();
                            case 'PICOVOICE_MISSING':
                            case 'MIC_ACCESS_DENIED':
                                return renderVoiceSetup();
                            default:
                                return renderGeneric();
                        }
                    })()}
                </div>
            </div>
        </div>
    );
}
