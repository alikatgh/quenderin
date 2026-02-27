import { useState, useEffect } from 'react';
import { Lock, ArrowRight } from 'lucide-react';

export function PrivacyLock({ isEnabled, expectedPassphrase, onUnlock }: { isEnabled: boolean, expectedPassphrase?: string, onUnlock: () => void }) {
    const [passphrase, setPassphrase] = useState('');
    const [error, setError] = useState(false);

    useEffect(() => {
        if (!isEnabled || !expectedPassphrase) {
            onUnlock();
        }
    }, [isEnabled, expectedPassphrase, onUnlock]);

    const handleSubmit = (e: React.FormEvent) => {
        e.preventDefault();
        if (passphrase === expectedPassphrase) {
            onUnlock();
        } else {
            setError(true);
            setTimeout(() => setError(false), 800);
            setPassphrase('');
        }
    };

    if (!isEnabled || !expectedPassphrase) return null;

    return (
        <div className="fixed inset-0 z-[999] flex items-center justify-center bg-black/40 backdrop-blur-2xl p-4 transition-all opacity-100 duration-500">
            <div className={`w-full max-w-sm bg-white dark:bg-[#121215] border border-zinc-200 dark:border-zinc-800 rounded-3xl shadow-[0_30px_60px_-15px_rgba(0,0,0,0.5)] p-8 overflow-hidden animate-in fade-in zoom-in-95 duration-500 ${error ? 'animate-shake' : ''}`}>
                <div className="flex justify-center mb-6">
                    <div className="w-16 h-16 bg-zinc-100 dark:bg-white/5 text-zinc-600 dark:text-zinc-400 rounded-2xl flex items-center justify-center shadow-inner border border-zinc-200 dark:border-white/10">
                        <Lock className="w-8 h-8" />
                    </div>
                </div>
                <h2 className="text-2xl font-bold text-center text-zinc-900 dark:text-white mb-2 tracking-tight">System Locked</h2>
                <p className="text-center text-sm text-zinc-500 dark:text-zinc-400 mb-8 font-medium">Enter your privacy passphrase to continue.</p>

                <form onSubmit={handleSubmit} className="relative">
                    <input
                        type="password"
                        autoFocus
                        value={passphrase}
                        onChange={e => { setPassphrase(e.target.value); setError(false); }}
                        placeholder="Passphrase"
                        className={`w-full bg-zinc-50 dark:bg-[#09090b] border ${error ? 'border-red-500 ring-2 ring-red-500/20 text-red-500' : 'border-zinc-200 dark:border-zinc-800 focus:border-zinc-400 dark:focus:border-zinc-600 focus:ring-2 focus:ring-zinc-500/10 text-zinc-900 dark:text-zinc-100'} rounded-2xl py-3.5 pl-5 pr-14 text-center tracking-[0.3em] font-mono text-lg placeholder:tracking-normal placeholder:font-sans placeholder:text-zinc-400 outline-none transition-all shadow-inner`}
                    />
                    <button type="submit" className="absolute right-2 top-2 bottom-2 aspect-square flex items-center justify-center rounded-xl bg-zinc-900 dark:bg-white text-white dark:text-zinc-900 hover:scale-105 active:scale-95 transition-all disabled:opacity-50 disabled:hover:scale-100" disabled={!passphrase}>
                        <ArrowRight className="w-5 h-5" />
                    </button>
                </form>
            </div>
        </div>
    );
}
