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
        <div className="p-5">
            <Smartphone className="w-5 h-5 text-emerald-500 mb-3" />
            <h2 className="text-lg font-semibold text-zinc-900 dark:text-white mb-1.5">Mobile Device Not Found</h2>
            <p className="text-zinc-500 dark:text-zinc-400 text-[13px] leading-relaxed mb-5">
                Ensure your virtual phone or mobile device is active.
            </p>

            <div className="space-y-3 mb-6">
                <div className="flex gap-2.5 text-[13px] items-start">
                    <Smartphone className="w-4 h-4 text-emerald-500 mt-0.5 flex-shrink-0" />
                    <div>
                        <p className="font-medium text-zinc-800 dark:text-zinc-200">1. Open your virtual phone</p>
                        <p className="text-zinc-400 dark:text-zinc-500 text-[12px] mt-0.5">Make sure your simulator (e.g. BlueStacks) is running.</p>
                    </div>
                </div>
                <div className="flex gap-2.5 text-[13px] items-start">
                    <Settings className="w-4 h-4 text-emerald-500 mt-0.5 flex-shrink-0" />
                    <div>
                        <p className="font-medium text-zinc-800 dark:text-zinc-200">2. Enable device link</p>
                        <p className="text-zinc-400 dark:text-zinc-500 text-[12px] mt-0.5">Turn on "Mobile Debugging" or "Device Link" in phone settings.</p>
                    </div>
                </div>
                <div className="flex gap-2.5 text-[13px] items-start">
                    <CheckCircle2 className="w-4 h-4 text-emerald-500 mt-0.5 flex-shrink-0" />
                    <div>
                        <p className="font-medium text-zinc-800 dark:text-zinc-200">3. Retry below</p>
                        <p className="text-zinc-400 dark:text-zinc-500 text-[12px] mt-0.5">Keep the emulator open and click Retry.</p>
                    </div>
                </div>
            </div>

            <button
                onClick={onResolved}
                className="w-full bg-emerald-600 hover:bg-emerald-700 text-white font-semibold py-2 px-4 rounded-xl transition-colors text-[13px]"
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
            <div className="p-5">
                <BrainCircuit className="w-5 h-5 text-purple-500 mb-3" />
                <h2 className="text-lg font-semibold text-zinc-900 dark:text-white mb-1.5">Choose an AI Model</h2>
                <p className="text-zinc-500 dark:text-zinc-400 text-[13px] leading-relaxed mb-5">
                    Pick a model based on how much RAM your computer has.
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
                                        <span className={`text-[10px] font-semibold px-2 py-0.5 rounded-full border ${ramColor(m.ramGb)}`}>{m.ramGb}GB RAM</span>
                                    </div>
                                    <span className="text-xs text-zinc-500">{m.sizeLabel} download</span>
                                </div>
                                <button
                                    onClick={() => handleDownload(m.id)}
                                    disabled={downloadProgress > 0}
                                    className="flex-shrink-0 flex items-center gap-1.5 px-3 py-1.5 bg-zinc-900 dark:bg-white text-white dark:text-zinc-900 text-xs font-semibold rounded-lg hover:opacity-90 transition-all disabled:opacity-40 disabled:cursor-not-allowed"
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
        <div className="p-5">
            <Monitor className="w-5 h-5 text-emerald-500 mb-3" />
            <h2 className="text-lg font-semibold text-zinc-900 dark:text-white mb-1.5">{action.title}</h2>
            <p className="text-zinc-500 dark:text-zinc-400 text-[13px] leading-relaxed mb-5">
                {action.message} Enable screen recording:
            </p>

            <div className="space-y-3 mb-6">
                <div className="flex gap-2.5 text-[13px] items-start">
                    <Settings className="w-4 h-4 text-emerald-500 mt-0.5 flex-shrink-0" />
                    <div>
                        <p className="font-medium text-zinc-800 dark:text-zinc-200">1. Open OS Settings</p>
                        <p className="text-zinc-400 dark:text-zinc-500 text-[12px] mt-0.5">System Settings &gt; Privacy &amp; Security.</p>
                    </div>
                </div>
                <div className="flex gap-2.5 text-[13px] items-start">
                    <Monitor className="w-4 h-4 text-emerald-500 mt-0.5 flex-shrink-0" />
                    <div>
                        <p className="font-medium text-zinc-800 dark:text-zinc-200">2. Screen Recording</p>
                        <p className="text-zinc-400 dark:text-zinc-500 text-[12px] mt-0.5">Select "Screen Recording" or "Screen &amp; System Audio Recording".</p>
                    </div>
                </div>
                <div className="flex gap-2.5 text-[13px] items-start">
                    <CheckCircle2 className="w-4 h-4 text-emerald-500 mt-0.5 flex-shrink-0" />
                    <div>
                        <p className="font-medium text-zinc-800 dark:text-zinc-200">3. Enable Quenderin</p>
                        <p className="text-zinc-400 dark:text-zinc-500 text-[12px] mt-0.5">Toggle the switch ON. You may need to restart.</p>
                    </div>
                </div>
            </div>

            <button
                onClick={onResolved}
                className="w-full bg-emerald-600 hover:bg-emerald-700 text-white font-semibold py-2 px-4 rounded-xl transition-colors text-[13px]"
            >
                Retry Connection
            </button>
        </div>
    );

    const renderVoiceSetup = () => (
        <div className="p-5">
            <AlertCircle className="w-5 h-5 text-amber-500 mb-3" />
            <h2 className="text-lg font-semibold text-zinc-900 dark:text-white mb-1.5">{action.title || 'Voice Setup'}</h2>
            <p className="text-zinc-500 dark:text-zinc-400 text-[13px] leading-relaxed mb-5">
                {action.message || 'Voice control is optional and currently unavailable. Text chat still works.'}
            </p>

            <div className="space-y-3 mb-6">
                <div className="flex gap-2.5 text-[13px] items-start">
                    <Settings className="w-4 h-4 text-amber-500 mt-0.5 flex-shrink-0" />
                    <div>
                        <p className="font-medium text-zinc-800 dark:text-zinc-200">1. Configure voice key (optional)</p>
                        <p className="text-zinc-400 dark:text-zinc-500 text-[12px] mt-0.5">Set <code className="bg-zinc-100 dark:bg-zinc-800 px-1 py-0.5 rounded text-[11px]">PICOVOICE_ACCESS_KEY</code> before launching.</p>
                    </div>
                </div>
                <div className="flex gap-2.5 text-[13px] items-start">
                    <CheckCircle2 className="w-4 h-4 text-emerald-500 mt-0.5 flex-shrink-0" />
                    <div>
                        <p className="font-medium text-zinc-800 dark:text-zinc-200">2. Or continue without voice</p>
                        <p className="text-zinc-400 dark:text-zinc-500 text-[12px] mt-0.5">Dismiss this and use text input normally.</p>
                    </div>
                </div>
            </div>

            <button
                onClick={onResolved}
                className="w-full bg-zinc-900 dark:bg-zinc-100 hover:bg-zinc-800 dark:hover:bg-white text-white dark:text-zinc-900 font-semibold py-2 px-4 rounded-xl transition-colors text-[13px]"
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
            <div className="p-5">
                <AlertTriangle className="w-5 h-5 text-amber-500 mb-3" />
                <h2 className="text-lg font-semibold text-zinc-900 dark:text-white mb-1.5">{action.title || 'Not Enough Free RAM'}</h2>
                <p className="text-zinc-500 dark:text-zinc-400 text-[13px] leading-relaxed mb-5">
                    {action.message || 'Your current model is too large for available RAM.'} Try a smaller model below.
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
                                        <span className={`text-[10px] font-semibold px-2 py-0.5 rounded-full border ${ramColor(m.ramGb)}`}>{m.ramGb}GB RAM</span>
                                        {isDownloaded && <span className="text-[10px] font-semibold text-emerald-600 dark:text-emerald-400">✓ installed</span>}
                                    </div>
                                    <span className="text-xs text-zinc-500">{m.sizeLabel} download</span>
                                </div>
                                {!isDownloaded ? (
                                    <button
                                        onClick={() => handleDownload(m.id)}
                                        disabled={downloadProgress > 0}
                                        className="flex-shrink-0 flex items-center gap-1.5 px-3 py-1.5 bg-zinc-900 dark:bg-white text-white dark:text-zinc-900 text-xs font-semibold rounded-lg hover:opacity-90 transition-all disabled:opacity-40 disabled:cursor-not-allowed"
                                    >
                                        <Download className="w-3.5 h-3.5" />
                                        Get
                                    </button>
                                ) : (
                                    <button
                                        onClick={onResolved}
                                        className="flex-shrink-0 flex items-center gap-1.5 px-3 py-1.5 bg-emerald-600 hover:bg-emerald-700 text-white text-xs font-semibold rounded-lg transition-all"
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
        <div className="p-5">
            <AlertTriangle className="w-5 h-5 text-amber-500 mb-3" />
            <h2 className="text-lg font-semibold text-zinc-900 dark:text-white mb-1.5">{action.title || 'System Reset Required'}</h2>
            <p className="text-zinc-500 dark:text-zinc-400 text-[13px] leading-relaxed mb-5">
                {action.message || "Something went wrong. Try these steps:"}
            </p>
            <div className="space-y-3 mb-6">
                <div className="flex gap-2.5 text-[13px] items-start">
                    <AlertTriangle className="w-4 h-4 text-amber-500 mt-0.5 flex-shrink-0" />
                    <div>
                        <p className="font-medium text-zinc-800 dark:text-zinc-200">1. Restart the app on device</p>
                        <p className="text-zinc-400 dark:text-zinc-500 text-[12px] mt-0.5">Force close and reopen the app you're testing.</p>
                    </div>
                </div>
                <div className="flex gap-2.5 text-[13px] items-start">
                    <RefreshCw className="w-4 h-4 text-amber-500 mt-0.5 flex-shrink-0" />
                    <div>
                        <p className="font-medium text-zinc-800 dark:text-zinc-200">2. Reset Quenderin</p>
                        <p className="text-zinc-400 dark:text-zinc-500 text-[12px] mt-0.5">Click "Restart System" below.</p>
                    </div>
                </div>
                <div className="flex gap-2.5 text-[13px] items-start">
                    <CheckCircle2 className="w-4 h-4 text-amber-500 mt-0.5 flex-shrink-0" />
                    <div>
                        <p className="font-medium text-zinc-800 dark:text-zinc-200">3. Verify connection</p>
                        <p className="text-zinc-400 dark:text-zinc-500 text-[12px] mt-0.5">Ensure the device is unlocked and on a stable screen.</p>
                    </div>
                </div>
            </div>
            <button onClick={() => window.location.reload()} className="w-full bg-amber-600 hover:bg-amber-700 text-white font-semibold py-2 px-4 rounded-xl transition-colors flex items-center justify-center gap-2 text-[13px]">
                <RefreshCw className="w-3.5 h-3.5" /> Restart System
            </button>
            <button onClick={onResolved} className="w-full mt-2 text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 font-medium py-1.5 rounded-xl transition-colors text-[13px]">
                Dismiss
            </button>
        </div>
    );

    return (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-zinc-900/40 dark:bg-black/60 backdrop-blur-md animate-in fade-in duration-200" role="dialog" aria-modal="true" aria-label="Troubleshooter">
            <div className="bg-white dark:bg-[#18181b] w-full max-w-lg rounded-2xl shadow-xl border border-zinc-200 dark:border-zinc-800 overflow-hidden flex flex-col">

                {/* Header */}
                <div className="px-5 py-3 border-b border-zinc-100 dark:border-zinc-800 flex items-center justify-between">
                    <h3 className="text-[13px] font-semibold text-zinc-700 dark:text-zinc-300">
                        Action Required
                    </h3>
                    <button
                        onClick={onResolved}
                        className="p-1.5 text-zinc-400 hover:text-zinc-600 hover:bg-zinc-100 dark:hover:bg-zinc-800 dark:hover:text-zinc-300 rounded-lg transition-colors"
                    >
                        <X className="w-4 h-4" />
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
