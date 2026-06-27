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

    // NOTE: this component must NEVER call onUnlock() as a side-effect of a prop change. It used to
    // auto-unlock whenever `!isEnabled || !expectedPassphrase` — but an empty passphrase ('') is falsy,
    // so a settings-sync race that momentarily emptied the passphrase auto-unlocked the lock with NO
    // user action (deep-hunt CRITICAL). The render gate below (`return null`) hides the overlay when the
    // lock isn't applicable; the PARENT owns the locked/unlocked state and onUnlock() now fires ONLY from
    // handleSubmit on a correct passphrase.

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
            setError(true);
            setTimeout(() => setError(false), 800);
            setPassphrase('');
            // Functional updater so the attempt count can't regress under a rapid double-submit (the
            // old `failedAttempts + 1` read a stale closure value) (deep-hunt).
            setFailedAttempts(prev => {
                const next = prev + 1;
                if (next >= MAX_FAILED_ATTEMPTS) {
                    setLockoutUntil(Date.now() + LOCKOUT_DURATION_MS);
                }
                return next;
            });
        }
    }, [passphrase, expectedPassphrase, onUnlock, lockoutUntil]);

    if (!isEnabled || !expectedPassphrase) return null;

    const isLockedOut = lockoutUntil !== null && Date.now() < lockoutUntil;

    return (
        <div className="fixed inset-0 z-[999] flex items-center justify-center bg-black/40 backdrop-blur-2xl p-4" role="dialog" aria-modal="true" aria-label="Privacy Lock">
            <div className={`w-full max-w-sm bg-white dark:bg-[#18181b] border border-zinc-200 dark:border-zinc-800 rounded-2xl shadow-xl p-8 overflow-hidden animate-in fade-in zoom-in-95 duration-500 ${error ? 'animate-shake' : ''}`}>
                <div className="flex justify-center mb-5">
                    {isLockedOut
                        ? <ShieldAlert className="w-7 h-7 text-red-500" />
                        : <Lock className="w-7 h-7 text-zinc-400 dark:text-zinc-500" />
                    }
                </div>
                <h2 className="text-xl font-semibold text-center text-zinc-900 dark:text-white mb-1.5 tracking-tight">
                    {isLockedOut ? 'Too Many Attempts' : 'Locked'}
                </h2>
                <p className="text-center text-[13px] text-zinc-500 dark:text-zinc-400 mb-6">
                    {isLockedOut
                        ? `Locked for ${Math.floor(lockoutRemaining / 60)}:${(lockoutRemaining % 60).toString().padStart(2, '0')}. Please wait.`
                        : failedAttempts > 0
                            ? `Enter passphrase (${MAX_FAILED_ATTEMPTS - failedAttempts} attempts left)`
                            : 'Enter your passphrase to continue.'}
                </p>

                <form onSubmit={handleSubmit} className="relative">
                    <input
                        type="password"
                        autoFocus
                        value={passphrase}
                        onChange={e => { setPassphrase(e.target.value); setError(false); }}
                        placeholder="Passphrase"
                        disabled={isLockedOut}
                        className={`w-full bg-zinc-50 dark:bg-[#09090b] border ${error ? 'border-red-500 ring-2 ring-red-500/20 text-red-500' : 'border-zinc-200 dark:border-zinc-800 focus:border-zinc-400 dark:focus:border-zinc-600 focus:ring-2 focus:ring-purple-500/10 text-zinc-900 dark:text-zinc-100'} rounded-xl py-3 pl-5 pr-14 text-center tracking-[0.25em] font-mono text-base placeholder:tracking-normal placeholder:font-sans placeholder:text-zinc-400 outline-none transition-all disabled:opacity-40 disabled:cursor-not-allowed`}
                    />
                    <button type="submit" className="absolute right-2 top-2 bottom-2 aspect-square flex items-center justify-center rounded-lg bg-zinc-900 dark:bg-white text-white dark:text-zinc-900 hover:scale-105 active:scale-95 transition-all disabled:opacity-50 disabled:hover:scale-100" disabled={!passphrase || isLockedOut}>
                        <ArrowRight className="w-4 h-4" />
                    </button>
                </form>
            </div>
        </div>
    );
}
