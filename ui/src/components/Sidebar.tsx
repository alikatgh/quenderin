import { useState, useEffect } from 'react';
import { Sparkles, BookOpen, BrainCircuit, Smartphone, SlidersHorizontal, Clock, MessageSquareText, BarChart3, type LucideIcon } from 'lucide-react';
import { LogEntry } from '../types/index.js';
import { apiFetch } from '../lib/api.js';

interface SessionSummary {
    id: string;
    title: string;
    createdAt: string;
    updatedAt: string;
    messageCount: number;
}

interface SidebarProps {
    isOpen: boolean;
    wsReady: boolean;
    logs: LogEntry[];
    readinessStage?: string;
    readinessReady?: boolean;
    currentView: 'chat' | 'docs' | 'general_chat' | 'metrics' | 'settings';
    setCurrentView: (view: 'chat' | 'docs' | 'general_chat' | 'metrics' | 'settings') => void;
    onNewGoal: () => void;
    onSelectSession: (id: string) => void;   // Q-313: open a past conversation from Recent
    activeModel?: string;
    hardwareTier?: string;
}

const TIER_STYLES: Record<string, { label: string; dot: string }> = {
    powerful:    { label: 'Powerful',    dot: 'bg-emerald-500' },
    standard:    { label: 'Standard',    dot: 'bg-blue-500' },
    constrained: { label: 'Constrained', dot: 'bg-amber-500' },
    embedded:    { label: 'Embedded',    dot: 'bg-red-500' },
};

export function Sidebar({ isOpen, wsReady, readinessStage, readinessReady, currentView, setCurrentView, onNewGoal, onSelectSession, activeModel = 'Loading AI...', hardwareTier }: SidebarProps) {
    const modelLabel = activeModel.includes('/') ? activeModel.split('/').pop()! : activeModel;
    const backendReady = readinessReady ?? false;
    const backendStage = readinessStage ?? 'unknown';
    const tierInfo = hardwareTier ? TIER_STYLES[hardwareTier] : null;
    const [recentSessions, setRecentSessions] = useState<SessionSummary[]>([]);

    useEffect(() => {
        apiFetch('/api/sessions')
            .then(r => r.ok ? r.json() : null)
            .then(data => {
                if (data?.sessions) setRecentSessions(data.sessions.slice(0, 5));
            })
            .catch(() => {});
    }, [currentView]);

    const navItem = (
        view: typeof currentView,
        label: string,
        Icon: LucideIcon,
    ) => {
        const active = currentView === view;
        return (
            <button
                key={view}
                onClick={() => setCurrentView(view)}
                aria-current={active ? 'page' : undefined}
                className={`w-full flex items-center gap-2.5 px-3 py-2 text-[13px] font-medium rounded-lg transition-all duration-150 ${
                    active
                        ? 'bg-zinc-200/80 dark:bg-zinc-800/80 text-zinc-900 dark:text-zinc-100'
                        : 'text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800/50'
                }`}
            >
                <Icon className={`w-4 h-4 flex-shrink-0 ${active ? 'text-purple-600 dark:text-purple-400' : ''}`} />
                <span>{label}</span>
            </button>
        );
    };

    return (
        <div
            className={`flex-shrink-0 bg-zinc-50 dark:bg-[#141416] border-r border-zinc-200/80 dark:border-zinc-800/80 transition-all duration-300 ease-in-out flex flex-col fixed inset-y-0 left-0 xl:sticky xl:top-0 xl:self-stretch xl:inset-auto z-40 shadow-[8px_0_24px_rgba(0,0,0,0.06)] dark:shadow-[8px_0_24px_rgba(0,0,0,0.3)] xl:shadow-none
            ${isOpen ? 'w-[250px] translate-x-0' : 'w-0 -translate-x-full overflow-hidden'}`}
        >
            <div className="p-3 flex flex-col h-full min-w-[250px]">

                {/* New Goal */}
                <button
                    onClick={onNewGoal}
                    className="w-full flex items-center gap-2 px-3 py-2.5 bg-white dark:bg-zinc-800/80 hover:bg-zinc-50 dark:hover:bg-zinc-800 active:bg-zinc-100 dark:active:bg-zinc-700 border border-zinc-200/80 dark:border-zinc-700/80 text-zinc-900 dark:text-zinc-100 text-[13px] font-semibold rounded-xl transition-colors shadow-sm"
                >
                    <Sparkles className="w-4 h-4 text-purple-500" />
                    <span>New Conversation</span>
                </button>

                {/* Status bar */}
                <div className="mt-4 mx-1 flex items-center gap-2.5 px-3 py-2.5 rounded-xl bg-white/60 dark:bg-zinc-800/40 border border-zinc-200/50 dark:border-zinc-800/50">
                    <div className="relative flex-shrink-0">
                        <div className={`w-2 h-2 rounded-full ${wsReady ? 'bg-emerald-500' : 'bg-red-500'}`} />
                        {wsReady && <div className="absolute inset-0 w-2 h-2 rounded-full bg-emerald-500 animate-ping opacity-30" />}
                    </div>
                    <div className="min-w-0 flex-1">
                        <p className="text-[11px] font-semibold text-zinc-800 dark:text-zinc-200 truncate" title={activeModel}>
                            {modelLabel}
                        </p>
                        <p className={`text-[10px] font-medium ${backendReady ? 'text-emerald-600 dark:text-emerald-400' : 'text-amber-600 dark:text-amber-400'}`}>
                            {backendReady ? 'Ready' : backendStage}
                            {tierInfo && <span className="text-zinc-400 dark:text-zinc-500"> &middot; {tierInfo.label}</span>}
                        </p>
                    </div>
                    <BrainCircuit className="w-4 h-4 text-purple-500/50 flex-shrink-0" />
                </div>

                {/* Recent Sessions */}
                {recentSessions.length > 0 && (
                    <div className="mt-4 mx-1">
                        <h3 className="text-[10px] font-semibold text-zinc-400 dark:text-zinc-500 uppercase tracking-wider mb-1.5 px-2 flex items-center gap-1.5">
                            <Clock className="w-3 h-3" /> Recent
                        </h3>
                        <div className="space-y-0.5">
                            {recentSessions.map(s => (
                                <button
                                    key={s.id}
                                    onClick={() => onSelectSession(s.id)}
                                    className="w-full text-left px-2.5 py-1.5 rounded-lg hover:bg-zinc-200/50 dark:hover:bg-zinc-800/50 transition-colors group"
                                >
                                    <p className="text-[12px] text-zinc-600 dark:text-zinc-400 truncate group-hover:text-zinc-900 dark:group-hover:text-zinc-200">{s.title}</p>
                                    <p className="text-[10px] text-zinc-400 dark:text-zinc-600">{s.messageCount} msgs</p>
                                </button>
                            ))}
                        </div>
                    </div>
                )}

                {/* Nav */}
                <div className="mt-auto mx-1 space-y-0.5">
                    {navItem('general_chat', 'Chat', MessageSquareText)}
                    {navItem('chat', 'Device Agent', Smartphone)}
                    {navItem('metrics', 'Metrics', BarChart3)}

                    <div className="my-2 border-t border-zinc-200/60 dark:border-zinc-800/60" />

                    {navItem('settings', 'Settings', SlidersHorizontal)}
                    {navItem('docs', 'Help', BookOpen)}
                </div>
            </div>
        </div>
    );
}
