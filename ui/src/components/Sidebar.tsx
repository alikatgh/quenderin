import { useState, useEffect } from 'react';
import { Activity, TerminalSquare, Sparkles, BookOpen, Shield, BrainCircuit, Smartphone, Search, SlidersHorizontal, Clock, Cpu } from 'lucide-react';
import { LogEntry } from '../types/index.js';

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
    activeModel?: string;
    hardwareTier?: string;
}

const TIER_STYLES: Record<string, { label: string; className: string }> = {
    powerful:    { label: 'Powerful',    className: 'bg-emerald-100 text-emerald-800 dark:bg-emerald-500/15 dark:text-emerald-400 border-emerald-200 dark:border-emerald-500/20' },
    standard:    { label: 'Standard',    className: 'bg-blue-100 text-blue-800 dark:bg-blue-500/15 dark:text-blue-400 border-blue-200 dark:border-blue-500/20' },
    constrained: { label: 'Constrained', className: 'bg-amber-100 text-amber-800 dark:bg-amber-500/15 dark:text-amber-400 border-amber-200 dark:border-amber-500/20' },
    embedded:    { label: 'Embedded',    className: 'bg-red-100 text-red-800 dark:bg-red-500/15 dark:text-red-400 border-red-200 dark:border-red-500/20' },
};

export function Sidebar({ isOpen, wsReady, readinessStage, readinessReady, currentView, setCurrentView, onNewGoal, activeModel = 'Loading AI...', hardwareTier }: SidebarProps) {
    const modelLabel = activeModel.includes('/') ? activeModel.split('/').pop()! : activeModel;
    const backendReady = readinessReady ?? false;
    const backendStage = readinessStage ?? 'unknown';
    const [recentSessions, setRecentSessions] = useState<SessionSummary[]>([]);

    useEffect(() => {
        fetch('/api/sessions')
            .then(r => r.ok ? r.json() : null)
            .then(data => {
                if (data?.sessions) setRecentSessions(data.sessions.slice(0, 5));
            })
            .catch(() => {});
    }, [currentView]); // Re-fetch when view changes (after a session ends)

    return (
        <div
            className={`flex-shrink-0 bg-zinc-50 dark:bg-[#171717] border-r border-zinc-200 dark:border-[#2a2a2e] transition-all duration-300 ease-in-out flex flex-col fixed inset-y-0 left-0 xl:sticky xl:top-0 xl:self-stretch xl:inset-auto z-40 shadow-[16px_0_32px_rgba(0,0,0,0.08)] dark:shadow-[16px_0_32px_rgba(0,0,0,0.4)] xl:shadow-none 
            ${isOpen ? 'w-[260px] translate-x-0' : 'w-0 -translate-x-full overflow-hidden'}`}
        >
            <div className="p-4 flex flex-col h-full min-w-[260px]">

                {/* New Goal Button */}
                <button
                    onClick={onNewGoal}
                    className="w-full flex items-center justify-between px-3 py-2 bg-white dark:bg-[#232326] hover:bg-zinc-50 dark:hover:bg-[#2b2b2f] border border-zinc-200 dark:border-[#3a3a3f] text-zinc-900 dark:text-zinc-100 text-sm font-semibold rounded-lg transition-all duration-300 active:scale-[0.99] cursor-pointer shadow-sm group"
                >
                    <div className="flex items-center gap-2">
                        <TerminalSquare className="w-4 h-4 text-purple-600 dark:text-purple-400" />
                        <span>New Goal</span>
                    </div>
                    <Sparkles className="w-3.5 h-3.5 text-orange-500" />
                </button>

                {/* Utility strip (screenshot-inspired) */}
                <div className="mt-3 space-y-1.5 px-1">
                    <button
                        onClick={() => setCurrentView('general_chat')}
                        className="w-full flex items-center gap-2 px-2.5 py-2 text-[12px] font-medium text-zinc-600 dark:text-zinc-400 rounded-lg hover:bg-zinc-200/60 dark:hover:bg-white/5 hover:text-zinc-900 dark:hover:text-zinc-200 transition-colors"
                    >
                        <Search className="w-3.5 h-3.5" />
                        Search
                    </button>
                    <button
                        onClick={() => setCurrentView('settings')}
                        className="w-full flex items-center gap-2 px-2.5 py-2 text-[12px] font-medium text-zinc-600 dark:text-zinc-400 rounded-lg hover:bg-zinc-200/60 dark:hover:bg-white/5 hover:text-zinc-900 dark:hover:text-zinc-200 transition-colors"
                    >
                        <SlidersHorizontal className="w-3.5 h-3.5" />
                        Customize
                    </button>
                </div>

                {/* Status — single merged card */}
                <div className="mt-5 px-2">
                    <h3 className="text-[11px] font-bold text-zinc-400 dark:text-zinc-500 uppercase tracking-widest mb-3 flex items-center gap-2">
                        <Activity className="w-3 h-3" /> System Status
                    </h3>
                    <div className="flex items-center gap-3 bg-zinc-100/50 dark:bg-white/[0.03] p-3 rounded-2xl border border-zinc-200/50 dark:border-white/5 shadow-sm">
                        {/* Connection dot */}
                        <div className="relative flex-shrink-0">
                            <div className={`w-2 h-2 rounded-full ${wsReady ? 'bg-emerald-500 shadow-[0_0_8px_rgba(16,185,129,0.5)]' : 'bg-red-500 shadow-[0_0_8px_rgba(239,68,68,0.5)]'}`} />
                            {wsReady && <div className="absolute inset-0 w-2 h-2 rounded-full bg-emerald-500 animate-ping opacity-40" />}
                        </div>
                        {/* Divider */}
                        <div className="w-px h-7 bg-zinc-200 dark:bg-white/10 flex-shrink-0" />
                        {/* Model */}
                        <BrainCircuit className="w-4 h-4 text-purple-600 dark:text-purple-400 flex-shrink-0" />
                        <div className="min-w-0 flex-1">
                            <p className="text-[10px] font-bold uppercase tracking-tight text-zinc-400 dark:text-zinc-500 mb-0.5">AI Engine</p>
                            <p className="text-zinc-900 dark:text-zinc-100 font-bold leading-tight text-[11px] truncate" title={activeModel}>
                                {modelLabel}
                            </p>
                            <p className={`text-[10px] mt-1 font-semibold uppercase tracking-tight ${backendReady ? 'text-emerald-600 dark:text-emerald-400' : 'text-amber-600 dark:text-amber-400'}`}>
                                Backend {backendReady ? 'ready' : backendStage}
                            </p>
                        </div>
                    </div>
                </div>

                {/* Hardware Tier Badge */}
                {hardwareTier && TIER_STYLES[hardwareTier] && (
                    <div className="mt-3 px-2">
                        <div className={`flex items-center gap-2 px-3 py-2 rounded-xl border text-[11px] font-semibold ${TIER_STYLES[hardwareTier].className}`}>
                            <Cpu className="w-3.5 h-3.5 flex-shrink-0" />
                            <span>{TIER_STYLES[hardwareTier].label} Hardware</span>
                        </div>
                    </div>
                )}

                {/* Recent Sessions */}
                {recentSessions.length > 0 && (
                    <div className="mt-5 px-2">
                        <h3 className="text-[11px] font-bold text-zinc-400 dark:text-zinc-500 uppercase tracking-widest mb-2 flex items-center gap-2">
                            <Clock className="w-3 h-3" /> Recent Sessions
                        </h3>
                        <div className="space-y-1">
                            {recentSessions.map(s => (
                                <button
                                    key={s.id}
                                    onClick={() => setCurrentView('general_chat')}
                                    className="w-full text-left px-2.5 py-2 rounded-lg hover:bg-zinc-200/60 dark:hover:bg-white/5 transition-colors group"
                                >
                                    <p className="text-[12px] font-medium text-zinc-700 dark:text-zinc-300 truncate group-hover:text-zinc-900 dark:group-hover:text-zinc-100">{s.title}</p>
                                    <p className="text-[10px] text-zinc-400 dark:text-zinc-500 mt-0.5">{s.messageCount} msgs · {new Date(s.updatedAt).toLocaleDateString([], { month: 'short', day: 'numeric' })}</p>
                                </button>
                            ))}
                        </div>
                    </div>
                )}

                {/* Nav */}
                <div className="mt-auto px-2 space-y-1">
                    <button
                        onClick={() => setCurrentView('general_chat')}
                        className={`w-full flex items-start gap-2.5 px-3 py-2 text-[13px] font-semibold rounded-lg transition-all duration-200 ${currentView === 'general_chat' ? 'bg-zinc-200/70 dark:bg-[#34343a]/70 text-zinc-900 dark:text-zinc-100' : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-200 hover:bg-zinc-200/50 dark:hover:bg-white/5'}`}
                    >
                        <div className="mt-0.5"><Activity className={`w-4 h-4 ${currentView === 'general_chat' ? 'text-purple-600' : ''}`} /></div>
                        <div className="text-left leading-tight mt-0.5">
                            General Chat<br />
                            <span className="text-[10px] font-semibold opacity-60">Private Conversation</span>
                        </div>
                    </button>

                    <button
                        onClick={() => setCurrentView('chat')}
                        className={`w-full flex items-start gap-2.5 px-3 py-2 text-[13px] font-semibold rounded-lg transition-all duration-200 ${currentView === 'chat' ? 'bg-zinc-200/70 dark:bg-[#34343a]/70 text-zinc-900 dark:text-zinc-100' : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-200 hover:bg-zinc-200/50 dark:hover:bg-white/5'}`}
                    >
                        <div className="mt-0.5"><Smartphone className={`w-4 h-4 ${currentView === 'chat' ? 'text-orange-500' : ''}`} /></div>
                        <div className="text-left leading-tight mt-0.5">
                            Spatial Assistant<br />
                            <span className="text-[10px] font-semibold opacity-60">Use Your Apps</span>
                        </div>
                    </button>

                    <button
                        onClick={() => setCurrentView('metrics')}
                        className={`w-full flex items-start gap-2.5 px-3 py-2 text-[13px] font-semibold rounded-lg transition-all duration-200 ${currentView === 'metrics' ? 'bg-zinc-200/70 dark:bg-[#34343a]/70 text-zinc-900 dark:text-zinc-100' : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-200 hover:bg-zinc-200/50 dark:hover:bg-white/5'}`}
                    >
                        <div className="mt-0.5"><Activity className={`w-4 h-4 ${currentView === 'metrics' ? 'text-blue-500' : ''}`} /></div>
                        <div className="text-left leading-tight mt-0.5">
                            Telemetry & Metrics<br />
                            <span className="text-[10px] font-semibold opacity-60">Assistant Efficiency</span>
                        </div>
                    </button>

                    <div className="my-2 border-b border-zinc-200 dark:border-[#27272a]" />

                    <button
                        onClick={() => setCurrentView('settings' as any)}
                        className={`w-full flex items-center gap-2 px-3 py-2 text-[13px] font-semibold rounded-lg transition-all duration-200 ${currentView === 'settings' ? 'bg-zinc-200/70 dark:bg-[#34343a]/70 text-zinc-900 dark:text-zinc-100' : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-200 hover:bg-zinc-200/50 dark:hover:bg-white/5'}`}
                    >
                        <Shield className={`w-4 h-4 ${currentView === 'settings' ? 'text-blue-500' : ''}`} />
                        System Settings
                    </button>

                    <button
                        onClick={() => setCurrentView('docs')}
                        className={`w-full flex items-center gap-2 px-3 py-2 text-[13px] font-semibold rounded-lg transition-all duration-200 ${currentView === 'docs' ? 'bg-purple-100 dark:bg-purple-500/20 text-purple-700 dark:text-purple-300' : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-200 hover:bg-zinc-200/50 dark:hover:bg-white/5'}`}
                    >
                        <BookOpen className="w-4 h-4" />
                        Help & Documentation
                    </button>
                </div>
            </div>
        </div>
    );
}
