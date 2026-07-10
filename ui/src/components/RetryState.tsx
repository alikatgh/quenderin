/**
 * The shared failed-to-load affordance (r38 #2, extracted at the third consumer): an empty state
 * is a CLAIM ("there is nothing") that a failed fetch can't back — so failures render THIS
 * instead, with the likely cause named and a real Retry. Keep the copy honest: say what
 * couldn't load, never pretend the data doesn't exist.
 */
export function RetryState({ message, onRetry, hint }: { message: string; onRetry: () => void; hint?: string }) {
    return (
        <div className="text-center py-6" role="alert">
            <p className="text-sm text-zinc-600 dark:text-zinc-400 mb-1">{message}</p>
            {hint && <p className="text-xs text-zinc-500 dark:text-zinc-500 mb-3">{hint}</p>}
            <button
                onClick={onRetry}
                className={`px-3 py-1.5 text-[12px] font-semibold text-purple-700 dark:text-purple-400 border border-purple-200 dark:border-purple-500/30 rounded-lg hover:bg-purple-50 dark:hover:bg-purple-500/10 transition-colors ${hint ? '' : 'mt-2'}`}
            >
                Retry
            </button>
        </div>
    );
}
