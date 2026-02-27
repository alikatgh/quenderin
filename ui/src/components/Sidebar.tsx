import { Activity, Clock, TerminalSquare, Sparkles, BookOpen, Shield, BrainCircuit, Smartphone } from 'lucide-react';
import { LogEntry } from '../types/index.js';

interface SidebarProps {
    isOpen: boolean;
    wsReady: boolean;
    logs: LogEntry[];
    currentView: 'chat' | 'docs' | 'general_chat' | 'metrics' | 'settings';
    setCurrentView: (view: 'chat' | 'docs' | 'general_chat' | 'metrics' | 'settings') => void;
    onNewGoal: () => void;
    activeModel?: string;
}

export function Sidebar({ isOpen, wsReady, logs, currentView, setCurrentView, onNewGoal, activeModel = 'Loading AI...' }: SidebarProps) {
    return (
        <div
            className={`flex-shrink-0 bg-zinc-50 dark:bg-[#18181b] border-r border-zinc-200 dark:border-[#27272a] transition-all duration-300 ease-in-out flex flex-col absolute xl:relative z-40 h-full shadow-[20px_0_40px_rgba(0,0,0,0.1)] dark:shadow-[20px_0_40px_rgba(0,0,0,0.5)] xl:shadow-none 
            ${isOpen ? 'w-[260px] translate-x-0' : 'w-0 -translate-x-full overflow-hidden'}`}
        >
            <div className="p-4 flex flex-col h-full min-w-[260px]">
                {/* New Goal Button */}
                <button
                    onClick={onNewGoal}
                    className="w-full flex items-center justify-between px-3 py-2 bg-white dark:bg-[#27272a] hover:bg-zinc-50 dark:hover:bg-[#323235] border border-zinc-200 dark:border-[#3f3f46] text-zinc-900 dark:text-zinc-100 text-sm font-semibold rounded-lg transition-all duration-300 hover:scale-[1.02] active:scale-[0.98] cursor-pointer shadow-sm hover:shadow-md group"
                >
                    <div className="flex items-center gap-2">
                        <TerminalSquare className="w-4 h-4 text-purple-600 dark:text-purple-400" />
                        <span>New Goal</span>
                    </div>
                    <Sparkles className="w-3.5 h-3.5 text-orange-500 animate-pulse" />
                </button>

                {/* Connection Status */}
                <div className="mt-8 px-2">
                    <h3 className="text-[11px] font-bold text-zinc-400 dark:text-zinc-500 uppercase tracking-widest mb-3 flex items-center gap-2">
                        <Activity className="w-3 h-3" /> System Status
                    </h3>
                    <div className="space-y-2">
                        {/* Control Link */}
                        <div className="flex items-center gap-3 bg-zinc-100/50 dark:bg-white/[0.03] p-3 rounded-2xl border border-zinc-200/50 dark:border-white/5 shadow-sm">
                            <div className="relative">
                                <div className={`w-2 h-2 rounded-full ${wsReady ? 'bg-emerald-500 shadow-[0_0_8px_rgba(16,185,129,0.5)]' : 'bg-red-500 shadow-[0_0_8px_rgba(239,68,68,0.5)]'}`} />
                                {wsReady && <div className="absolute inset-0 w-2 h-2 rounded-full bg-emerald-500 animate-ping opacity-40" />}
                            </div>
                            <div className="min-w-0 flex-1">
                                <p className="text-[10px] font-bold uppercase tracking-tight text-zinc-400 dark:text-zinc-500 mb-0.5">Control Server</p>
                                <p className="text-zinc-900 dark:text-zinc-100 font-bold leading-tight text-[12px] truncate">LOCALHOST:3000</p>
                            </div>
                        </div>

                        {/* AI Brain */}
                        <div className="flex items-center gap-3 bg-zinc-100/50 dark:bg-white/[0.03] p-3 rounded-2xl border border-zinc-200/50 dark:border-white/5 shadow-sm">
                            <BrainCircuit className="w-4 h-4 text-purple-600 dark:text-purple-400" />
                            <div className="min-w-0 flex-1">
                                <p className="text-[10px] font-bold uppercase tracking-tight text-zinc-400 dark:text-zinc-500 mb-0.5">AI Engine</p>
                                <p className="text-zinc-900 dark:text-zinc-100 font-bold leading-tight text-[11px] truncate" title={activeModel}>
                                    {activeModel.includes('/') ? activeModel.split('/').pop() : activeModel}
                                </p>
                            </div>
                        </div>
                    </div>
                </div>

                <div className="mt-6 px-2">
                    <h3 className="text-[11px] font-bold text-zinc-400 dark:text-zinc-500 uppercase tracking-widest mb-3 flex items-center gap-2">
                        <Clock className="w-3 h-3" /> Recent Session
                    </h3>
                    {logs.length > 0 ? (
                        <div
                            onClick={() => setCurrentView('chat')}
                            className="text-[13px] text-zinc-700 dark:text-zinc-200 bg-zinc-100/50 dark:bg-white/[0.03] border border-zinc-200 dark:border-white/5 p-4 rounded-2xl leading-relaxed line-clamp-3 hover:translate-x-1 cursor-pointer transition-all duration-300 font-medium shadow-sm hover:shadow-md"
                        >
                            "{logs[0]?.message.replace('Goal set: ', '') || 'Active session'}"
                        </div>
                    ) : (
                        <div className="text-[13px] text-zinc-400 dark:text-zinc-600 italic">No history available.</div>
                    )}
                </div>

                <div className="mt-auto px-2 space-y-1">
                    <button
                        onClick={() => setCurrentView('general_chat')}
                        className={`w-full flex items-start gap-2.5 px-3 py-2.5 text-[13px] font-bold rounded-xl transition-all duration-200 ${currentView === 'general_chat' ? 'bg-zinc-200/80 dark:bg-[#3f3f46]/60 text-zinc-900 dark:text-white shadow-sm ring-1 ring-black/5' : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-200 hover:bg-zinc-200/50 dark:hover:bg-white/5'}`}
                    >
                        <div className="mt-0.5"><Activity className={`w-4 h-4 ${currentView === 'general_chat' ? 'text-purple-600' : ''}`} /></div>
                        <div className="text-left leading-tight mt-0.5">
                            General Chat<br />
                            <span className="text-[10px] font-semibold opacity-60">Private Conversation</span>
                        </div>
                    </button>

                    <button
                        onClick={() => setCurrentView('chat')}
                        className={`w-full flex items-start gap-2.5 px-3 py-2.5 text-[13px] font-bold rounded-xl transition-all duration-200 ${currentView === 'chat' ? 'bg-zinc-200/80 dark:bg-[#3f3f46]/60 text-zinc-900 dark:text-white shadow-sm ring-1 ring-black/5' : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-200 hover:bg-zinc-200/50 dark:hover:bg-white/5'}`}
                    >
                        <div className="mt-0.5"><Smartphone className={`w-4 h-4 ${currentView === 'chat' ? 'text-orange-500' : ''}`} /></div>
                        <div className="text-left leading-tight mt-0.5">
                            Spatial Assistant<br />
                            <span className="text-[10px] font-semibold opacity-60">Use Your Apps</span>
                        </div>
                    </button>

                    <button
                        onClick={() => setCurrentView('metrics')}
                        className={`w-full flex items-start gap-2.5 px-3 py-2 text-[13px] font-medium rounded-lg transition-colors ${currentView === 'metrics' ? 'bg-zinc-200/60 dark:bg-[#3f3f46]/40 text-zinc-900 dark:text-zinc-100' : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-[#27272a]'}`}
                    >
                        <div className="mt-0.5"><Activity className="w-4 h-4 text-blue-500" /></div>
                        <div className="text-left leading-tight mt-0.5">
                            Telemetry & Metrics<br />
                            <span className="text-[10px] font-normal opacity-70">Assistant Efficiency</span>
                        </div>
                    </button>

                    <div className="my-2 border-b border-zinc-200 dark:border-[#27272a]"></div>
                    <button
                        onClick={() => setCurrentView('settings' as any)}
                        className={`w-full flex items-center gap-2 px-3 py-2.5 text-[13px] font-bold rounded-xl transition-all duration-200 ${currentView === 'settings' as any ? 'bg-zinc-200/80 dark:bg-[#3f3f46]/60 text-zinc-900 dark:text-white shadow-sm ring-1 ring-black/5' : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-200 hover:bg-zinc-200/50 dark:hover:bg-white/5'}`}
                    >
                        <Shield className={`w-4 h-4 ${currentView === 'settings' ? 'text-blue-500' : ''}`} />
                        System Settings
                    </button>

                    <button
                        onClick={() => setCurrentView('docs')}
                        className={`w-full flex items-center gap-2 px-3 py-2.5 text-[13px] font-bold rounded-xl transition-all duration-200 ${currentView === 'docs' ? 'bg-purple-100 dark:bg-purple-500/20 text-purple-700 dark:text-purple-300 shadow-sm ring-1 ring-purple-500/10' : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-200 hover:bg-zinc-200/50 dark:hover:bg-white/5'}`}
                    >
                        <BookOpen className="w-4 h-4" />
                        Help & Documentation
                    </button>
                </div>
            </div>
        </div>
    );
}
