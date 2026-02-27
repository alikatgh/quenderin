import { useState } from 'react';
import { Smartphone, Usb, Settings, CheckCircle2, Mic, Save, AlertTriangle, BrainCircuit, Download, RefreshCw, X, AlertCircle, Monitor } from 'lucide-react';

interface TroubleshooterPayload {
    code: string;
    title: string;
    message: string;
    autoTrigger?: string;
}

interface TroubleshooterGuideProps {
    action: TroubleshooterPayload | null;
    onResolved: () => void;
    onTriggerDownload: () => void;
    downloadProgress?: number;
}

export function TroubleshooterGuide({ action, onResolved, onTriggerDownload, downloadProgress = 0 }: TroubleshooterGuideProps) {
    const [picovoiceKey, setPicovoiceKey] = useState('');
    const [isSaving, setIsSaving] = useState(false);

    if (!action) return null;

    const handleSaveKey = async () => {
        setIsSaving(true);
        try {
            if (picovoiceKey.trim()) {
                await fetch('/api/config/voice', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ key: picovoiceKey.trim() })
                });
                onResolved(); // It was fixed!
            }
        } catch (e) {
            console.error("Failed to save key", e);
        }
        setIsSaving(false);
    };

    const renderAdbMissing = () => (
        <div className="p-6">
            <div className="w-12 h-12 bg-emerald-100 dark:bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 rounded-xl flex items-center justify-center mb-5 border border-emerald-200 dark:border-emerald-500/20 shadow-sm">
                <Smartphone className="w-6 h-6" />
            </div>
            <h2 className="text-xl font-bold text-zinc-900 dark:text-white mb-2">{action.title}</h2>
            <p className="text-zinc-600 dark:text-zinc-400 text-sm leading-relaxed mb-6">
                {action.message} Let's fix this in 3 quick steps:
            </p>

            <div className="space-y-4 mb-8">
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><Settings className="w-4 h-4 text-emerald-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">1. Developer Options</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">Go to Settings &gt; About Phone. Tap "Build Number" 7 times.</p>
                    </div>
                </div>
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><Usb className="w-4 h-4 text-emerald-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">2. Enable USB Debugging</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">Go back to Settings &gt; Developer Options. Toggle "USB Debugging" ON.</p>
                    </div>
                </div>
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><CheckCircle2 className="w-4 h-4 text-emerald-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">3. Trust Computer</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">Plug via USB (or start Emulator). Tap "Always allow from this computer" on the RSA prompt.</p>
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

    const renderPicovoiceMissing = () => (
        <div className="p-6">
            <div className="w-12 h-12 bg-emerald-100 dark:bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 rounded-xl flex items-center justify-center mb-5 border border-emerald-200 dark:border-emerald-500/20 shadow-sm">
                <Mic className="w-6 h-6" />
            </div>
            <h2 className="text-xl font-bold text-zinc-900 dark:text-white mb-2">{action.title}</h2>
            <p className="text-zinc-600 dark:text-zinc-400 text-sm leading-relaxed mb-4">
                {action.message}
            </p>
            <div className="mb-6">
                <p className="text-xs text-zinc-500 dark:text-zinc-400 mb-2">1. Create a free account at `console.picovoice.ai`</p>
                <p className="text-xs text-zinc-500 dark:text-zinc-400 mb-4">2. Copy your Access Key and paste it below:</p>
                <input
                    type="text"
                    placeholder="Paste Access Key..."
                    value={picovoiceKey}
                    onChange={(e) => setPicovoiceKey(e.target.value)}
                    className="w-full bg-zinc-50 dark:bg-zinc-800 border-zinc-300 dark:border-zinc-700 text-zinc-900 dark:text-white rounded-xl px-4 py-3 text-[13px] font-mono focus:outline-none focus:ring-2 focus:ring-emerald-500/50 shadow-sm transition-all"
                />
            </div>
            <div className="flex gap-3">
                <button onClick={onResolved} className="flex-1 bg-zinc-100 hover:bg-zinc-200 dark:bg-zinc-800 dark:hover:bg-zinc-700 text-zinc-900 dark:text-white font-semibold py-2.5 px-4 rounded-xl transition-colors">
                    Not Now
                </button>
                <button onClick={handleSaveKey} disabled={isSaving || !picovoiceKey.trim()} className="flex-[2] bg-emerald-600 hover:bg-emerald-700 text-white font-semibold py-2.5 px-4 rounded-xl transition-colors flex items-center justify-center gap-2 disabled:opacity-50">
                    {isSaving ? "Saving..." : <>Save Key <Save className="w-4 h-4" /></>}
                </button>
            </div>
        </div>
    );

    const renderModelMissing = () => (
        <div className="p-6">
            <div className="w-12 h-12 bg-emerald-100 dark:bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 rounded-xl flex items-center justify-center mb-5 border border-emerald-200 dark:border-emerald-500/20 shadow-sm">
                <BrainCircuit className="w-6 h-6" />
            </div>
            <h2 className="text-xl font-bold text-zinc-900 dark:text-white mb-2">{action.title}</h2>
            <p className="text-zinc-600 dark:text-zinc-400 text-sm leading-relaxed mb-6">
                {action.message} Understanding your AI Brain:
            </p>

            <div className="space-y-4 mb-8">
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><BrainCircuit className="w-4 h-4 text-emerald-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">1. Offline Intelligence</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">Quenderin uses a completely private, offline AI model to process your screen data securely.</p>
                    </div>
                </div>
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><Download className="w-4 h-4 text-emerald-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">2. Automatic Download</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">We will download the AI files directly to your computer so it runs locally.</p>
                    </div>
                </div>
                <div className="flex gap-3 text-sm items-start">
                    <div className="mt-0.5"><RefreshCw className="w-4 h-4 text-emerald-500" /></div>
                    <div>
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">3. Engine Initialization</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">Once cached, the system will inject the weights into RAM and reboot the cognitive pipeline instantly.</p>
                    </div>
                </div>
            </div>

            {downloadProgress === 100 ? (
                <div className="animate-in fade-in duration-300">
                    <div className="bg-emerald-50 dark:bg-emerald-900/20 border border-emerald-200 dark:border-emerald-500/30 rounded-xl p-4 mb-6 flex items-start gap-3">
                        <CheckCircle2 className="w-5 h-5 text-emerald-500 shrink-0 mt-0.5" />
                        <div>
                            <p className="text-sm font-semibold text-emerald-900 dark:text-emerald-300">Weights Installed Successfully</p>
                            <p className="text-xs text-emerald-700 dark:text-emerald-400 mt-1">The 4.7GB AI engine is installed locally.</p>
                        </div>
                    </div>
                    <button onClick={() => window.location.reload()} className="w-full bg-emerald-600 hover:bg-emerald-700 text-white font-semibold py-2.5 px-4 rounded-xl transition-colors flex items-center justify-center gap-2 shadow-sm">
                        <RefreshCw className="w-4 h-4" /> Restart Engine
                    </button>
                </div>
            ) : downloadProgress > 0 ? (
                <div className="animate-in fade-in duration-300">
                    <div className="flex justify-between text-xs font-semibold mb-2">
                        <span className="text-emerald-600 dark:text-emerald-400">Downloading AI Model (Llama 3)...</span>
                        <span className="text-zinc-500 dark:text-zinc-400">{downloadProgress}%</span>
                    </div>
                    <div className="w-full bg-zinc-100 dark:bg-zinc-800 rounded-full h-3 mb-2 overflow-hidden border border-zinc-200 dark:border-zinc-700">
                        <div
                            className="bg-emerald-500 h-3 transition-all duration-300 ease-out"
                            style={{ width: `${downloadProgress}%` }}
                        ></div>
                    </div>
                    <p className="text-[11px] text-zinc-500 dark:text-zinc-400 text-center uppercase tracking-widest mt-4">
                        Do not close the application
                    </p>
                </div>
            ) : (
                <div className="animate-in fade-in duration-300">
                    <button onClick={onTriggerDownload} className="w-full bg-zinc-900 hover:bg-zinc-800 dark:bg-zinc-100 dark:hover:bg-white text-white dark:text-zinc-900 font-semibold py-2.5 px-4 rounded-xl transition-colors flex items-center justify-center gap-2 shadow-sm">
                        <Download className="w-4 h-4" /> Download Brain Automatically (4.7GB)
                    </button>
                    <button onClick={onResolved} className="w-full mt-3 text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 font-medium py-2 rounded-xl transition-colors text-sm">
                        Dismiss
                    </button>
                </div>
            )}
        </div>
    );

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
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">Toggle the switch ON for Quenderin (or your terminal). You may need to restart the app.</p>
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

    const renderGeneric = () => (
        <div className="p-6">
            <div className="w-12 h-12 bg-amber-100 dark:bg-amber-500/10 text-amber-600 dark:text-amber-400 rounded-xl flex items-center justify-center mb-5 border border-amber-200 dark:border-amber-500/20 shadow-sm">
                <AlertTriangle className="w-6 h-6" />
            </div>
            <h2 className="text-xl font-bold text-zinc-900 dark:text-white mb-2">Engine Recalibration Required</h2>
            <p className="text-zinc-600 dark:text-zinc-400 text-sm leading-relaxed mb-6">
                Quenderin has encountered an unknown state block. Let's reset the environment:
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
                        <p className="font-semibold text-zinc-900 dark:text-zinc-200">2. Restart Quenderin Engine</p>
                        <p className="text-zinc-500 dark:text-zinc-400 text-xs mt-1">Click the "Safely Restart Engine" button below to reboot the cognitive pipeline.</p>
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
                <RefreshCw className="w-4 h-4" /> Safely Restart Engine
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
                            case 'PICOVOICE_MISSING':
                                return renderPicovoiceMissing();
                            case 'MODEL_MISSING':
                                return renderModelMissing();
                            default:
                                return renderGeneric();
                        }
                    })()}
                </div>
            </div>
        </div>
    );
}
