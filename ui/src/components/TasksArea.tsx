import { useEffect, useRef, useState } from 'react';
import { ListChecks, Square, Undo2, FolderOpen } from 'lucide-react';
import { TaskLogItem, TaskApproval } from '../hooks/useAgentSocket.js';

/**
 * The Tasks view — the dashboard front-end for the GOVERNED agent (`quenderin do` with a GUI):
 * describe a chore, watch the plan execute step by step, answer each approval question, and undo
 * the whole task afterwards. The safety semantics live on the server (fail-closed approval,
 * ledger, kill switch); this surface only renders them honestly:
 *  - the approval dialog's safe action is "Don't allow" (initial focus + Escape),
 *  - Stop is always visible while a task runs,
 *  - a finished task with reversible changes always shows Undo.
 */

interface TasksAreaProps {
    status: 'idle' | 'running' | 'done' | 'error';
    log: TaskLogItem[];
    approval: TaskApproval | null;
    undoable: number;
    wsReady: boolean;
    onStart: (goal: string, opts: { workspace?: string; gui?: boolean; dryRun?: boolean }) => boolean;
    onApprove: (id: string, approved: boolean) => void;
    onStop: () => void;
    onUndo: () => void;
}

const LOG_STYLES: Record<TaskLogItem['kind'], string> = {
    info: 'text-zinc-500 dark:text-zinc-400 font-medium',
    step: 'text-zinc-500 dark:text-zinc-400',
    answer: 'text-zinc-900 dark:text-zinc-100 font-medium',
    halt: 'text-amber-700 dark:text-amber-400',
    error: 'text-red-700 dark:text-red-400',
    undone: 'text-emerald-700 dark:text-emerald-400',
};

export function TasksArea({ status, log, approval, undoable, wsReady, onStart, onApprove, onStop, onUndo }: TasksAreaProps) {
    const [goal, setGoal] = useState('');
    const [workspace, setWorkspace] = useState('');
    const [dryRun, setDryRun] = useState(false);
    const logEndRef = useRef<HTMLDivElement>(null);
    const declineRef = useRef<HTMLButtonElement>(null);

    const running = status === 'running';

    // Keep the newest activity in view; keyed on length so token-free step streams still scroll.
    useEffect(() => {
        logEndRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' });
    }, [log.length]);

    // The approval dialog: focus lands on the SAFE answer, and Escape means no (fail-closed).
    useEffect(() => {
        if (!approval) return;
        declineRef.current?.focus();
        const onKey = (e: KeyboardEvent) => {
            if (e.key === 'Escape') onApprove(approval.id, false);
        };
        window.addEventListener('keydown', onKey);
        return () => window.removeEventListener('keydown', onKey);
    }, [approval, onApprove]);

    const start = () => {
        const trimmed = goal.trim();
        if (!trimmed || running) return;
        if (onStart(trimmed, { workspace: workspace.trim() || undefined, dryRun })) setGoal('');
    };

    return (
        <div className="flex-1 flex flex-col min-h-0">
            <div className="flex-1 overflow-y-auto px-4 sm:px-6 py-5">
                <div className="max-w-2xl mx-auto space-y-5">
                    <div>
                        <h1 className="text-[15px] font-semibold text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                            <ListChecks className="w-4 h-4 text-purple-600 dark:text-purple-400" aria-hidden="true" />
                            Tasks
                        </h1>
                        <p className="mt-1 text-[13px] leading-relaxed text-zinc-500 dark:text-zinc-400">
                            Describe a chore and Quenderin does it on this computer — planned by the local model,
                            every change previewed and approved by you, all of it logged and undoable.
                            Nothing leaves this machine.
                        </p>
                    </div>

                    {/* Goal + options */}
                    <div className="rounded-xl border border-zinc-200/80 dark:border-zinc-800/80 bg-zinc-50/50 dark:bg-zinc-900/40 p-3 space-y-3">
                        <label className="block">
                            <span className="text-[11px] font-semibold uppercase tracking-wide text-zinc-400 dark:text-zinc-500">Goal</span>
                            <textarea
                                value={goal}
                                onChange={(e) => setGoal(e.target.value)}
                                onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); start(); } }}
                                placeholder="e.g. organize this folder’s files into subfolders by type"
                                rows={2}
                                disabled={running}
                                className="mt-1 w-full resize-none rounded-lg border border-zinc-200/80 dark:border-zinc-700/80 bg-white dark:bg-zinc-800/80 px-3 py-2 text-[13px] text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 dark:placeholder:text-zinc-500 focus:outline-none focus-visible:ring-2 focus-visible:ring-purple-500 disabled:opacity-60"
                            />
                        </label>
                        <label className="block">
                            <span className="text-[11px] font-semibold uppercase tracking-wide text-zinc-400 dark:text-zinc-500 flex items-center gap-1">
                                <FolderOpen className="w-3 h-3" aria-hidden="true" /> Workspace folder (for file tasks)
                            </span>
                            <input
                                type="text"
                                value={workspace}
                                onChange={(e) => setWorkspace(e.target.value)}
                                placeholder="~/Downloads — the ONE folder the agent may touch"
                                disabled={running}
                                className="mt-1 w-full rounded-lg border border-zinc-200/80 dark:border-zinc-700/80 bg-white dark:bg-zinc-800/80 px-3 py-2 text-[13px] font-mono text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 dark:placeholder:text-zinc-500 placeholder:font-sans focus:outline-none focus-visible:ring-2 focus-visible:ring-purple-500 disabled:opacity-60"
                            />
                        </label>
                        <div className="flex items-center justify-between gap-3">
                            <label className="flex items-center gap-2 text-[12px] text-zinc-600 dark:text-zinc-400 select-none">
                                <input
                                    type="checkbox"
                                    checked={dryRun}
                                    onChange={(e) => setDryRun(e.target.checked)}
                                    disabled={running}
                                    className="rounded border-zinc-300 dark:border-zinc-600 text-purple-600 focus:ring-purple-500"
                                />
                                Dry run — show what it would do, change nothing
                            </label>
                            {running ? (
                                <button
                                    type="button"
                                    onClick={onStop}
                                    className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-red-300/60 dark:border-red-500/40 text-[12px] font-semibold text-red-700 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-500/10 transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-red-500"
                                >
                                    <Square className="w-3 h-3" aria-hidden="true" /> Stop
                                </button>
                            ) : (
                                <button
                                    type="button"
                                    onClick={start}
                                    disabled={!wsReady || !goal.trim()}
                                    className="px-4 py-1.5 rounded-lg bg-purple-600 hover:bg-purple-700 text-[12px] font-semibold text-white transition-colors disabled:opacity-40 disabled:hover:bg-purple-600 focus:outline-none focus-visible:ring-2 focus-visible:ring-purple-500"
                                >
                                    Run task
                                </button>
                            )}
                        </div>
                    </div>

                    {/* Activity */}
                    {log.length > 0 && (
                        <div className="rounded-xl border border-zinc-200/80 dark:border-zinc-800/80 p-3" role="log" aria-label="Task activity">
                            <ul className="space-y-1.5">
                                {log.map((item) => (
                                    <li key={item.id} className={`text-[12.5px] leading-relaxed whitespace-pre-wrap ${LOG_STYLES[item.kind]}`}>
                                        {item.kind === 'step' ? `· ${item.text}` : item.text}
                                    </li>
                                ))}
                            </ul>
                            {running && (
                                <p className="mt-2 text-[12px] text-zinc-400 dark:text-zinc-500 motion-safe:animate-pulse">working…</p>
                            )}
                            {!running && undoable > 0 && (
                                <button
                                    type="button"
                                    onClick={onUndo}
                                    className="mt-3 flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-zinc-300/80 dark:border-zinc-700/80 text-[12px] font-semibold text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-purple-500"
                                >
                                    <Undo2 className="w-3.5 h-3.5" aria-hidden="true" />
                                    Undo everything this task changed
                                    <span className="tabular-nums text-zinc-400 dark:text-zinc-500">({undoable})</span>
                                </button>
                            )}
                            <div ref={logEndRef} />
                        </div>
                    )}
                </div>
            </div>

            {/* The approval dialog — the heart of the trust loop. */}
            {approval && (
                <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/50 backdrop-blur-sm">
                    <div
                        role="dialog"
                        aria-modal="true"
                        aria-labelledby="task-approval-title"
                        className="w-full max-w-md rounded-xl border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-900 p-4"
                    >
                        <h2 id="task-approval-title" className="text-[13px] font-semibold text-zinc-900 dark:text-zinc-100">
                            Allow this action?
                        </h2>
                        <p className="mt-2 text-[13px] leading-relaxed text-zinc-700 dark:text-zinc-300 whitespace-pre-wrap">
                            {approval.summary}
                        </p>
                        <p className="mt-2 text-[11px] text-zinc-400 dark:text-zinc-500">
                            Nothing runs without your yes. Dismissing counts as no.
                        </p>
                        <div className="mt-4 flex justify-end gap-2">
                            <button
                                ref={declineRef}
                                type="button"
                                onClick={() => onApprove(approval.id, false)}
                                className="px-3 py-1.5 rounded-lg border border-zinc-300/80 dark:border-zinc-700/80 text-[12px] font-semibold text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-purple-500"
                            >
                                Don’t allow
                            </button>
                            <button
                                type="button"
                                onClick={() => onApprove(approval.id, true)}
                                className="px-3 py-1.5 rounded-lg bg-purple-600 hover:bg-purple-700 text-[12px] font-semibold text-white transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-purple-500"
                            >
                                Allow
                            </button>
                        </div>
                    </div>
                </div>
            )}
        </div>
    );
}
