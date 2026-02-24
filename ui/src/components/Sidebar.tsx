import { Activity, Clock, TerminalSquare, Sparkles, Sun, Moon, BookOpen } from 'lucide-react';
import { useTheme } from '../context/ThemeContext.js';
import { LogEntry } from '../types/index.js';

interface SidebarProps {
    isOpen: boolean;
    wsReady: boolean;
    logs: LogEntry[];
    currentView: 'chat' | 'docs' | 'general_chat' | 'metrics';
    setCurrentView: (view: 'chat' | 'docs' | 'general_chat' | 'metrics') => void;
    onNewGoal: () => void;
    activeModel?: string;
}

export function Sidebar({ isOpen, wsReady, logs, currentView, setCurrentView, onNewGoal, activeModel = 'Loading...' }: SidebarProps) {
    const { isDarkMode, toggleTheme } = useTheme();

    return (
        <div
            className={`flex-shrink-0 bg-zinc-50 dark:bg-[#18181b] border-r border-zinc-200 dark:border-[#27272a] transition-all duration-300 ease-in-out flex flex-col absolute xl:relative z-40 h-full shadow-[20px_0_40px_rgba(0,0,0,0.1)] dark:shadow-[20px_0_40px_rgba(0,0,0,0.5)] xl:shadow-none ${isOpen ? 'w-[260px] translate-x-0' : 'w-0 -translate-x-full overflow-hidden'}`}
        >
            <div className="p-4 flex flex-col h-full min-w-[260px]">
                {/* New Goal Button */}
                <button
                    onClick={onNewGoal}
                    className="w-full flex items-center justify-between px-3 py-2 bg-white dark:bg-[#18181b] hover:bg-zinc-100 dark:hover:bg-[#27272a] border border-zinc-200 dark:border-[#3f3f46] text-zinc-700 dark:text-zinc-200 text-sm font-medium rounded-lg transition-colors cursor-pointer"
                >
                    <div className="flex items-center gap-2">
                        <TerminalSquare className="w-4 h-4 text-zinc-500 dark:text-zinc-400" />
                        <span>New Goal</span>
                    </div>
                    <Sparkles className="w-3.5 h-3.5 text-orange-500/80" />
                </button>

                {/* Connection Status */}
                <div className="mt-8 px-2">
                    <h3 className="text-xs font-semibold text-zinc-400 dark:text-zinc-500 uppercase tracking-wider mb-3 flex items-center gap-2">
                        <Activity className="w-3 h-3" /> System Status
                    </h3>
                    <div className="flex items-start gap-3 text-sm text-zinc-600 dark:text-zinc-400 bg-zinc-100/80 dark:bg-[#27272a]/50 p-3 rounded-xl border border-zinc-200/80 dark:border-[#3f3f46]/50">
                        <div className="mt-1 flex-shrink-0">
                            <div className={`w-2 h-2 rounded-full ${wsReady ? 'bg-emerald-500 shadow-[0_0_8px_rgba(16,185,129,0.3)] dark:shadow-[0_0_8px_rgba(16,185,129,0.5)]' : 'bg-red-500'}`} />
                        </div>
                        <div>
                            <p className="text-zinc-800 dark:text-zinc-200 font-medium leading-tight">Android ADB Daemon</p>
                            <p className="text-[11px] mt-1 opacity-80 font-mono">localhost:3000</p>
                            <p className="text-[11px] opacity-80 font-mono mt-0.5" title={activeModel}>
                                {activeModel.length > 25 ? activeModel.substring(0, 25) + '...' : activeModel}
                            </p>
                        </div>
                    </div>
                </div>

                <div className="mt-6 px-2">
                    <h3 className="text-xs font-semibold text-zinc-400 dark:text-zinc-500 uppercase tracking-wider mb-3 flex items-center gap-2">
                        <Clock className="w-3 h-3" /> Recent Session
                    </h3>
                    {logs.length > 0 ? (
                        <div
                            onClick={() => setCurrentView('chat')}
                            className="text-[13px] text-zinc-600 dark:text-zinc-300 bg-zinc-100/80 dark:bg-[#27272a]/50 border border-zinc-200/80 dark:border-[#3f3f46]/50 p-3 rounded-xl leading-snug line-clamp-3 hover:border-purple-300 dark:hover:border-purple-500/50 cursor-pointer transition-colors"
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
                        className={`w-full flex items-start gap-2.5 px-3 py-2 text-[13px] font-medium rounded-lg transition-colors ${currentView === 'general_chat' ? 'bg-zinc-200/60 dark:bg-[#3f3f46]/40 text-zinc-900 dark:text-zinc-100' : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-[#27272a]'}`}
                    >
                        <div className="mt-0.5"><Activity className="w-4 h-4" /></div>
                        <div className="text-left leading-tight mt-0.5">
                            General Chat<br />
                            <span className="text-[10px] font-normal opacity-70">Talk to Local LLM</span>
                        </div>
                    </button>

                    <button
                        onClick={() => setCurrentView('chat')}
                        className={`w-full flex items-start gap-2.5 px-3 py-2 text-[13px] font-medium rounded-lg transition-colors ${currentView === 'chat' ? 'bg-zinc-200/60 dark:bg-[#3f3f46]/40 text-zinc-900 dark:text-zinc-100' : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-[#27272a]'}`}
                    >
                        <div className="mt-0.5"><TerminalSquare className="w-4 h-4" /></div>
                        <div className="text-left leading-tight mt-0.5">
                            Spatial Agent<br />
                            <span className="text-[10px] font-normal opacity-70">Run on Android UI</span>
                        </div>
                    </button>

                    <button
                        onClick={() => setCurrentView('metrics')}
                        className={`w-full flex items-start gap-2.5 px-3 py-2 text-[13px] font-medium rounded-lg transition-colors ${currentView === 'metrics' ? 'bg-zinc-200/60 dark:bg-[#3f3f46]/40 text-zinc-900 dark:text-zinc-100' : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-[#27272a]'}`}
                    >
                        <div className="mt-0.5"><Activity className="w-4 h-4 text-blue-500" /></div>
                        <div className="text-left leading-tight mt-0.5">
                            Telemetry & Metrics<br />
                            <span className="text-[10px] font-normal opacity-70">Agent Performance</span>
                        </div>
                    </button>

                    <div className="my-2 border-b border-zinc-200 dark:border-[#27272a]"></div>
                    <button
                        onClick={toggleTheme}
                        className="w-full flex items-center gap-2 px-3 py-2 text-[13px] font-medium text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-200 hover:bg-zinc-200 dark:hover:bg-[#27272a] rounded-lg transition-colors"
                    >
                        {isDarkMode ? <Sun className="w-4 h-4" /> : <Moon className="w-4 h-4" />}
                        Toggle Theme
                    </button>

                    <button
                        onClick={() => setCurrentView('docs')}
                        className={`w-full flex items-center gap-2 px-3 py-2 text-[13px] font-medium rounded-lg transition-colors ${currentView === 'docs' ? 'bg-purple-100 dark:bg-purple-500/20 text-purple-700 dark:text-purple-300' : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-200 hover:bg-zinc-200 dark:hover:bg-[#27272a]'}`}
                    >
                        <BookOpen className="w-4 h-4" />
                        Help & Documentation
                    </button>
                </div>
            </div>
        </div>
    );
}
