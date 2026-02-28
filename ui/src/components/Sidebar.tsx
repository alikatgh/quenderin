import { TerminalSquare, Sparkles, BookOpen, Shield, BrainCircuit, Smartphone, MessageSquare, BarChart2 } from 'lucide-react';
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

type NavItem = {
    id: 'chat' | 'docs' | 'general_chat' | 'metrics' | 'settings';
    label: string;
    Icon: React.ElementType;
    accent: string;
};

const NAV_MAIN: NavItem[] = [
    { id: 'general_chat', label: 'General Chat',       Icon: MessageSquare, accent: 'text-purple-500' },
    { id: 'chat',         label: 'Spatial Assistant',  Icon: Smartphone,    accent: 'text-orange-500' },
    { id: 'metrics',      label: 'Telemetry & Metrics',Icon: BarChart2,     accent: 'text-blue-500'   },
];

const NAV_FOOT: NavItem[] = [
    { id: 'settings', label: 'System Settings', Icon: Shield,   accent: 'text-blue-500'   },
    { id: 'docs',     label: 'Help & Docs',     Icon: BookOpen, accent: 'text-violet-500' },
];

export function Sidebar({ isOpen, wsReady, logs, currentView, setCurrentView, onNewGoal, activeModel = 'Loading AI...' }: SidebarProps) {
    const modelLabel = activeModel.includes('/') ? activeModel.split('/').pop()! : activeModel;
    const lastGoal   = logs[0]?.message.replace('Goal set: ', '') || null;

    const navBtn = ({ id, label, Icon, accent }: NavItem) => {
        const active = currentView === id;
        return (
            <button
                key={id}
                onClick={() => setCurrentView(id)}
                className={`w-full flex items-center gap-2.5 px-3 py-2 rounded-lg text-[13px] font-medium transition-all duration-150
                    ${active
                        ? 'bg-zinc-200/80 dark:bg-white/[0.07] text-zinc-900 dark:text-white'
                        : 'text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-white/5'
                    }`}
            >
                <Icon className={`w-4 h-4 flex-shrink-0 ${active ? accent : ''}`} />
                {label}
            </button>
        );
    };

    return (
        <div
            className={`flex-shrink-0 bg-zinc-50 dark:bg-[#18181b] border-r border-zinc-200 dark:border-[#27272a] transition-all duration-300 ease-in-out flex flex-col absolute xl:relative z-40 h-full shadow-[20px_0_40px_rgba(0,0,0,0.1)] dark:shadow-[20px_0_40px_rgba(0,0,0,0.5)] xl:shadow-none 
            ${isOpen ? 'w-[220px] translate-x-0' : 'w-0 -translate-x-full overflow-hidden'}`}
        >
            <div className="p-3 flex flex-col h-full min-w-[220px] gap-4">

                {/* New Goal */}
                <button
                    onClick={onNewGoal}
                    className="flex items-center justify-between px-3 py-2 bg-white dark:bg-[#27272a] hover:bg-zinc-50 dark:hover:bg-[#323235] border border-zinc-200 dark:border-[#3f3f46] text-zinc-900 dark:text-zinc-100 text-[13px] font-semibold rounded-lg transition-all duration-200 hover:scale-[1.01] active:scale-[0.99] shadow-sm"
                >
                    <div className="flex items-center gap-2">
                        <TerminalSquare className="w-3.5 h-3.5 text-purple-600 dark:text-purple-400" />
                        New Goal
                    </div>
                    <Sparkles className="w-3 h-3 text-orange-500 animate-pulse" />
                </button>

                {/* Status strip — two slim rows */}
                <div className="space-y-1.5 px-1">
                    <div className="flex items-center gap-2 px-2.5 py-1.5 rounded-lg bg-zinc-100/60 dark:bg-white/[0.03] border border-zinc-200/60 dark:border-white/5">
                        <div className="relative flex-shrink-0">
                            <div className={`w-1.5 h-1.5 rounded-full ${wsReady ? 'bg-emerald-500 shadow-[0_0_5px_rgba(16,185,129,0.6)]' : 'bg-red-500 shadow-[0_0_5px_rgba(239,68,68,0.6)]'}`} />
                            {wsReady && <div className="absolute inset-0 w-1.5 h-1.5 rounded-full bg-emerald-500 animate-ping opacity-40" />}
                        </div>
                        <span className="text-[11px] font-medium text-zinc-500 dark:text-zinc-400 truncate">localhost:3000</span>
                    </div>
                    <div className="flex items-center gap-2 px-2.5 py-1.5 rounded-lg bg-zinc-100/60 dark:bg-white/[0.03] border border-zinc-200/60 dark:border-white/5">
                        <BrainCircuit className="w-3 h-3 text-purple-500 dark:text-purple-400 flex-shrink-0" />
                        <span className="text-[11px] font-medium text-zinc-600 dark:text-zinc-300 truncate" title={activeModel}>{modelLabel}</span>
                    </div>
                </div>

                {/* Last session — compact ghost line, only when present */}
                {lastGoal && (
                    <button
                        onClick={() => setCurrentView('chat')}
                        className="px-1 text-left group"
                        title={lastGoal}
                    >
                        <span className="block text-[9px] font-bold uppercase tracking-widest text-zinc-300 dark:text-zinc-600 mb-0.5">Last session</span>
                        <span className="text-[11.5px] text-zinc-400 dark:text-zinc-500 group-hover:text-zinc-600 dark:group-hover:text-zinc-300 leading-snug line-clamp-2 transition-colors italic">
                            "{lastGoal}"
                        </span>
                    </button>
                )}

                {/* Main nav */}
                <nav className="px-1 space-y-0.5">
                    <p className="px-3 mb-1 text-[9px] font-bold uppercase tracking-widest text-zinc-350 dark:text-zinc-600">Views</p>
                    {NAV_MAIN.map(navBtn)}
                </nav>

                {/* Footer nav */}
                <nav className="mt-auto px-1 pt-3 border-t border-zinc-200 dark:border-[#27272a] space-y-0.5">
                    {NAV_FOOT.map(navBtn)}
                </nav>
            </div>
        </div>
    );
}
