import { useState, useEffect } from 'react';
import { Brain, ChevronDown, ChevronRight, AlertTriangle } from 'lucide-react';
import { apiFetch } from '../../lib/api.js';

/**
 * Agent Memory panel — extracted from SettingsArea (r38/r44 split, 2026-07-11). Self-contained:
 * lazy-fetches trajectories on first expand; clear-all is confirm-gated. Moved verbatim.
 */
export function MemorySection() {
    const [trajectories, setTrajectories] = useState<{ goal: string; actionCount: number; timestamp: string }[]>([]);
    const [memoryOpen, setMemoryOpen] = useState(false);
    const [memoryTotal, setMemoryTotal] = useState(0);
    const [clearingMemory, setClearingMemory] = useState(false);

    useEffect(() => {
        if (memoryOpen) {
            apiFetch('/api/memory/trajectories').then(r => r.ok ? r.json() : null).then(d => { if (d) { setTrajectories(d.trajectories); setMemoryTotal(d.total); } }).catch(() => {});
        }
    }, [memoryOpen]);

    const handleClearMemory = async () => {
        if (!confirm('Clear all agent learned trajectories? The agent will start fresh without any prior experience.')) return;
        setClearingMemory(true);
        await apiFetch('/api/memory/trajectories', { method: 'DELETE' }).catch(() => {});
        setTrajectories([]);
        setMemoryTotal(0);
        setClearingMemory(false);
    };

    return (
        <section className="premium-card p-6">
            <button
                type="button"
                aria-expanded={memoryOpen}
                onClick={() => setMemoryOpen(o => !o)}
                className="w-full flex items-center justify-between rounded-lg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-purple-500/40"
            >
                <div className="flex items-center gap-3">
                    <Brain className="w-5 h-5 text-purple-500" />
                    <div className="text-left">
                        <h2 className="text-[15px] font-semibold text-zinc-900 dark:text-white">Agent Memory</h2>
                        <p className="text-[12px] text-zinc-500 dark:text-zinc-400">Goals the spatial agent has learned to complete successfully.</p>
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
                                <div key={`${t.timestamp}-${i}`} className="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800">
                                    <p className="text-[13px] font-medium text-zinc-800 dark:text-zinc-200 leading-snug">{t.goal}</p>
                                    <p className="text-[10px] text-zinc-400 dark:text-zinc-500 mt-1 tabular-nums">{t.actionCount} actions · {new Date(t.timestamp).toLocaleDateString([], { month: 'short', day: 'numeric' })}</p>
                                </div>
                            ))}
                        </div>
                    )}
                </div>
            )}
        </section>
    );
}
