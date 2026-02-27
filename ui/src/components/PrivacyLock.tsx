import { useState, useEffect, useCallback } from 'react';
import { Lock, ArrowRight, ShieldAlert } from 'lucide-react';

/** Max failed attempts before lockout (ported from off-grid-mobile auth store) */
const MAX_FAILED_ATTEMPTS = 5;
/** Lockout duration in ms (5 minutes) */
const LOCKOUT_DURATION_MS = 5 * 60 * 1000;

/** Hash a passphrase with SHA-256 so we never compare plaintext */
async function hashPassphrase(input: string): Promise<string> {
    const encoded = new TextEncoder().encode(input);
    const digest = await crypto.subtle.digest('SHA-256', encoded);
    return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
}

export function PrivacyLock({ isEnabled, expectedPassphrase, onUnlock }: { isEnabled: boolean, expectedPassphrase?: string, onUnlock: () => void }) {
    const [passphrase, setPassphrase] = useState('');
    const [error, setError] = useState(false);
    const [failedAttempts, setFailedAttempts] = useState(0);
    const [lockoutUntil, setLockoutUntil] = useState<number | null>(null);
    const [lockoutRemaining, setLockoutRemaining] = useState(0);

    useEffect(() => {
        if (!isEnabled || !expectedPassphrase) {
            onUnlock();
        }
    }, [isEnabled, expectedPassphrase, onUnlock]);

    // Countdown timer during lockout
    useEffect(() => {
        if (!lockoutUntil) return;
        const tick = () => {
            const remaining = lockoutUntil - Date.now();
            if (remaining <= 0) {
                setLockoutUntil(null);
                setFailedAttempts(0);
                setLockoutRemaining(0);
            } else {
                setLockoutRemaining(Math.ceil(remaining / 1000));
            }
        };
        tick();
        const interval = setInterval(tick, 1000);
        return () => clearInterval(interval);
    }, [lockoutUntil]);

    const handleSubmit = useCallback(async (e: React.FormEvent) => {
        e.preventDefault();
        if (lockoutUntil && Date.now() < lockoutUntil) return;

        if (!expectedPassphrase) return;

        // Compare SHA-256 hashes instead of plaintext
        const inputHash = await hashPassphrase(passphrase);
        const expectedHash = await hashPassphrase(expectedPassphrase);

        if (inputHash === expectedHash) {
            setFailedAttempts(0);
            setLockoutUntil(null);
            onUnlock();
        } else {
            const newAttempts = failedAttempts + 1;
            setFailedAttempts(newAttempts);
            setError(true);
            setTimeout(() => setError(false), 800);
            setPassphrase('');

            if (newAttempts >= MAX_FAILED_ATTEMPTS) {
                setLockoutUntil(Date.now() + LOCKOUT_DURATION_MS);
            }
        }
    }, [passphrase, expectedPassphrase, onUnlock, failedAttempts, lockoutUntil]);

    if (!isEnabled || !expectedPassphrase) return null;

    const isLockedOut = lockoutUntil !== null && Date.now() < lockoutUntil;

    return (
        <div className="fixed inset-0 z-[999] flex items-center justify-center bg-black/40 backdrop-blur-2xl p-4 transition-all opacity-100 duration-500">
            <div className={`w-full max-w-sm bg-white dark:bg-[#121215] border border-zinc-200 dark:border-zinc-800 rounded-3xl shadow-[0_30px_60px_-15px_rgba(0,0,0,0.5)] p-8 overflow-hidden animate-in fade-in zoom-in-95 duration-500 ${error ? 'animate-shake' : ''}`}>
                <div className="flex justify-center mb-6">
                    <div className={`w-16 h-16 ${isLockedOut ? 'bg-red-100 dark:bg-red-500/10 text-red-600 dark:text-red-400 border-red-200 dark:border-red-500/10' : 'bg-zinc-100 dark:bg-white/5 text-zinc-600 dark:text-zinc-400 border-zinc-200 dark:border-white/10'} rounded-2xl flex items-center justify-center shadow-inner border`}>
                        {isLockedOut ? <ShieldAlert className="w-8 h-8" /> : <Lock className="w-8 h-8" />}
                    </div>
                </div>
                <h2 className="text-2xl font-bold text-center text-zinc-900 dark:text-white mb-2 tracking-tight">
                    {isLockedOut ? 'Too Many Attempts' : 'System Locked'}
                </h2>
                <p className="text-center text-sm text-zinc-500 dark:text-zinc-400 mb-8 font-medium">
                    {isLockedOut
                        ? `Locked for ${Math.floor(lockoutRemaining / 60)}:${(lockoutRemaining % 60).toString().padStart(2, '0')}. Please wait.`
                        : failedAttempts > 0
                            ? `Enter your passphrase (${MAX_FAILED_ATTEMPTS - failedAttempts} attempts remaining)`
                            : 'Enter your privacy passphrase to continue.'}
                </p>

                <form onSubmit={handleSubmit} className="relative">
                    <input
                        type="password"
                        autoFocus
                        value={passphrase}
                        onChange={e => { setPassphrase(e.target.value); setError(false); }}
                        placeholder="Passphrase"
                        disabled={isLockedOut}
                        className={`w-full bg-zinc-50 dark:bg-[#09090b] border ${error ? 'border-red-500 ring-2 ring-red-500/20 text-red-500' : 'border-zinc-200 dark:border-zinc-800 focus:border-zinc-400 dark:focus:border-zinc-600 focus:ring-2 focus:ring-zinc-500/10 text-zinc-900 dark:text-zinc-100'} rounded-2xl py-3.5 pl-5 pr-14 text-center tracking-[0.3em] font-mono text-lg placeholder:tracking-normal placeholder:font-sans placeholder:text-zinc-400 outline-none transition-all shadow-inner disabled:opacity-40 disabled:cursor-not-allowed`}
                    />
                    <button type="submit" className="absolute right-2 top-2 bottom-2 aspect-square flex items-center justify-center rounded-xl bg-zinc-900 dark:bg-white text-white dark:text-zinc-900 hover:scale-105 active:scale-95 transition-all disabled:opacity-50 disabled:hover:scale-100" disabled={!passphrase || isLockedOut}>
                        <ArrowRight className="w-5 h-5" />
                    </button>
                </form>
            </div>
        </div>
    );
}
