import { useState, useEffect } from 'react';
import { Shield, Bell, Monitor, Moon, Sun, ArrowLeft, Save, CheckCircle2, RotateCcw } from 'lucide-react';

interface Settings {
    contextSize: number;
    memorySafetyEnabled: boolean;
    chatLogDedupeMs: number;
    themePreference: 'light' | 'dark' | 'system';
    privacyLockEnabled: boolean;
    privacyPassphrase: string;
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

export function SettingsArea({ onBack, currentSettings, onSave, onReset, onThemeChange, contextOptions, hardwareTier, lastOutageInfo, onClearOutageHistory, readinessStage }: SettingsAreaProps) {
    const [settings, setSettings] = useState<Settings>(currentSettings);
    const [isSaved, setIsSaved] = useState(false);
    const [diagCopied, setDiagCopied] = useState(false);

    useEffect(() => {
        setSettings(currentSettings);
    }, [currentSettings]);

    const handleSave = () => {
        onSave(settings);
        setIsSaved(true);
        setTimeout(() => setIsSaved(false), 2000);
    };

    const handleCopyDiagnostics = async () => {
        try {
            let serverDiagnostics: unknown = null;
            let serverDiagnosticsError: string | null = null;

            try {
                const controller = new AbortController();
                const timeout = setTimeout(() => controller.abort(), 2500);
                try {
                    const response = await fetch('/diagnostics?historyLimit=5', { cache: 'no-store', signal: controller.signal });

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
                diagnosticsSchemaVersion: '1.0.0',
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

            const payload = JSON.stringify(summary, null, 2);
            await navigator.clipboard.writeText(payload);
            setDiagCopied(true);
            setTimeout(() => setDiagCopied(false), 1800);
        } catch {
            setDiagCopied(false);
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
                                                {diagCopied ? 'Copied!' : 'Copy diagnostics'}
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
