import { useRef, useEffect } from 'react';
import { Sparkles, BookOpen, ArrowRight, User, AlertCircle, Activity, Eye, BrainCircuit, Zap, CheckCircle2, Loader2, Send } from 'lucide-react';
import { LogEntry } from '../types/index.js';

interface ChatAreaProps {
    logs: LogEntry[];
    status: 'idle' | 'running' | 'done';
    goal: string;
    setGoal: (goal: string) => void;
    onStart: (goal: string) => void;
    setCurrentView: (view: 'chat' | 'docs') => void;
}

export function ChatArea({ logs, status, goal, setGoal, onStart, setCurrentView }: ChatAreaProps) {
    const logsEndRef = useRef<HTMLDivElement>(null);
    const textareaRef = useRef<HTMLTextAreaElement>(null);

    useEffect(() => {
        if (logsEndRef.current) {
            logsEndRef.current.scrollIntoView({ behavior: 'smooth' });
        }
    }, [logs]);

    useEffect(() => {
        if (textareaRef.current) {
            textareaRef.current.style.height = 'auto';
            textareaRef.current.style.height = Math.min(textareaRef.current.scrollHeight, 200) + 'px';
        }
    }, [goal]);

    const getTypeIcon = (type: string) => {
        switch (type) {
            case 'status': return <Activity className="w-4 h-4 text-zinc-400 dark:text-zinc-500" />;
            case 'observe': return <Eye className="w-4 h-4 text-blue-500 dark:text-blue-400" />;
            case 'decide': return <BrainCircuit className="w-4 h-4 text-purple-600 dark:text-purple-400" />;
            case 'action': return <Zap className="w-4 h-4 text-emerald-600 dark:text-emerald-400" />;
            case 'error': return <AlertCircle className="w-4 h-4 text-red-500 dark:text-red-400" />;
            case 'done': return <CheckCircle2 className="w-4 h-4 text-zinc-500 dark:text-zinc-400" />;
            default: return <Activity className="w-4 h-4 text-zinc-400" />;
        }
    }

    const handleStart = () => {
        if (goal.trim()) {
            onStart(goal);
        }
    };

    return (
        <>
            <div className="flex-1 overflow-y-auto px-4 w-full">
                <div className="max-w-[760px] mx-auto pb-40">

                    {logs.length === 0 && (
                        <div className="mt-24 flex flex-col items-center animate-fade-in px-4">
                            <div className="w-16 h-16 bg-white dark:bg-[#27272a] rounded-2xl flex items-center justify-center mb-6 shadow-sm border border-zinc-200 dark:border-[#3f3f46]">
                                <Sparkles className="w-8 h-8 text-zinc-800 dark:text-zinc-300" />
                            </div>
                            <h2 className="text-3xl font-medium text-zinc-900 dark:text-white mb-2 tracking-tight">Agent Control Ready</h2>
                            <p className="text-zinc-500 dark:text-[#a1a1aa] mb-12 text-[15px]">Quenderin is connected and waiting for instructions.</p>

                            <div className="grid sm:grid-cols-2 gap-4 w-full">
                                <div
                                    onClick={() => setCurrentView('docs')}
                                    className="p-5 border border-zinc-200 dark:border-[#3f3f46] bg-zinc-50/50 dark:bg-[#27272a]/30 rounded-2xl hover:bg-zinc-100 dark:hover:bg-[#27272a]/60 hover:border-zinc-300 dark:hover:border-zinc-500 transition-colors cursor-pointer"
                                >
                                    <div className="flex items-center gap-2 mb-2">
                                        <BookOpen className="w-5 h-5 text-zinc-700 dark:text-zinc-300" />
                                        <h3 className="font-medium text-zinc-900 dark:text-zinc-100">Read Documentation</h3>
                                    </div>
                                    <p className="text-[13px] text-zinc-600 dark:text-zinc-400 leading-relaxed">
                                        Learn about the Quenderin Vision, offline local model compatibility, and how the ADB spatial extraction works.
                                    </p>
                                </div>

                                <div className="p-5 border border-zinc-200 dark:border-[#3f3f46] bg-zinc-50/50 dark:bg-[#27272a]/30 rounded-2xl flex flex-col justify-center">
                                    <p className="text-[13px] text-zinc-600 dark:text-zinc-400 mb-3">Try asking the agent to:</p>
                                    <button
                                        onClick={() => { setGoal("Open Settings and turn on WiFi"); }}
                                        className="text-left bg-transparent px-3 py-1.5 -ml-3 rounded-lg text-[14px] text-zinc-800 dark:text-zinc-200 transition-colors hover:bg-zinc-100 dark:hover:bg-[#27272a] flex items-center gap-2 group font-medium"
                                    >
                                        "Open Settings and turn on WiFi" <ArrowRight className="w-3 h-3 opacity-0 group-hover:opacity-100 -ml-1 transition-all text-purple-500" />
                                    </button>
                                </div>
                            </div>
                        </div>
                    )}

                    {logs.length > 0 && (
                        <div className="mt-10 mb-8 w-full animate-fade-in">
                            <div className="flex justify-end mb-8">
                                <div className="max-w-[85%] bg-zinc-100 dark:bg-[#27272a] border border-zinc-200 dark:border-[#3f3f46] px-5 py-4 rounded-2xl rounded-tr-sm">
                                    <div className="flex items-center gap-2 mb-1 justify-end">
                                        <span className="text-xs font-medium text-zinc-500 dark:text-zinc-400">You</span>
                                        <User className="w-3.5 h-3.5 text-zinc-600 dark:text-zinc-500" />
                                    </div>
                                    <div className="text-[16px] text-zinc-900 dark:text-zinc-100 leading-relaxed font-medium whitespace-pre-wrap">
                                        {logs[0]?.message.replace('Goal set: ', '')}
                                    </div>
                                </div>
                            </div>

                            <div className="flex gap-4 sm:gap-6 mt-4">
                                <div className="w-8 h-8 sm:w-10 sm:h-10 rounded-xl bg-orange-100 border border-orange-200 text-orange-600 dark:bg-orange-500/10 dark:border-orange-500/20 dark:text-orange-400 flex flex-shrink-0 items-center justify-center">
                                    <Sparkles className="w-5 h-5" />
                                </div>

                                <div className="flex-1 min-w-0">
                                    <h4 className="text-[14px] font-medium text-zinc-900 dark:text-zinc-100 mb-4 mt-1">Agent Process Stream</h4>

                                    <div className="space-y-4">
                                        {logs.slice(1).map((log) => (
                                            <div key={log.id} className="animate-fade-in">
                                                {log.type === 'error' ? (
                                                    <div className="bg-red-50 dark:bg-red-500/10 border border-red-200 dark:border-red-500/20 rounded-xl p-4 flex items-start gap-3 mt-4 mb-2 shadow-sm">
                                                        <AlertCircle className="w-5 h-5 text-red-600 dark:text-red-400 flex-shrink-0 mt-0.5" />
                                                        <div className="text-[14px] text-red-800 dark:text-red-300 font-medium leading-relaxed whitespace-pre-wrap">
                                                            {log.message}
                                                        </div>
                                                    </div>
                                                ) : (
                                                    <div className="flex items-start gap-3 w-full">
                                                        <div className="mt-[2px] opacity-70 flex-shrink-0">{getTypeIcon(log.type)}</div>
                                                        <div className={`markdown-body w-full break-words min-w-0 ${log.type === 'done' ? 'text-zinc-900 dark:text-zinc-100 font-medium' : ''}`}>
                                                            {log.type === 'decide' ? (
                                                                <div className="flex items-center flex-wrap gap-2 text-[14px] text-zinc-700 dark:text-zinc-300">
                                                                    <span>Plan generated:</span>
                                                                    <code className="bg-zinc-100 dark:bg-[#27272a] font-mono tracking-tight text-[13px] px-2 py-0.5 rounded border border-zinc-200 dark:border-[#3f3f46] shadow-sm">{log.command}</code>
                                                                </div>
                                                            ) : (
                                                                <span>{log.message}</span>
                                                            )}
                                                        </div>
                                                    </div>
                                                )}
                                            </div>
                                        ))}

                                        {status === 'running' && (
                                            <div className="flex items-center gap-2 mt-4 text-zinc-500">
                                                <Loader2 className="w-4 h-4 animate-spin" />
                                                <span className="text-[14px]">Interpreting visual hierarchy...</span>
                                            </div>
                                        )}
                                    </div>
                                </div>
                            </div>

                            <div ref={logsEndRef} className="h-1" />
                        </div>
                    )}
                </div>
            </div>

            <div className="absolute bottom-0 left-0 right-0 bg-gradient-to-t from-white via-white dark:from-[#18181b] dark:via-[#18181b] to-transparent pt-12 pb-6 px-4 pointer-events-none">
                <div className="claude-input-wrapper pointer-events-auto">
                    <textarea
                        ref={textareaRef}
                        className="claude-textarea"
                        placeholder="How can I automate for you today?"
                        value={goal}
                        onChange={(e) => setGoal(e.target.value)}
                        disabled={status === 'running'}
                        rows={1}
                        onKeyDown={(e) => {
                            if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); handleStart() }
                        }}
                    />
                    <div className="absolute right-2.5 bottom-2.5">
                        <button
                            onClick={handleStart}
                            disabled={status === 'running' || !goal.trim()}
                            className={`p-1.5 rounded-lg transition-colors ${(status === 'running' || !goal.trim()) ? 'text-zinc-400 dark:text-zinc-600 bg-transparent' : 'bg-black dark:bg-white text-white dark:text-black hover:bg-zinc-800 dark:hover:bg-zinc-200'}`}
                        >
                            {status === 'running' ? <Activity className="w-[18px] h-[18px] animate-spin" /> : <Send className="w-[18px] h-[18px] ml-0.5" />}
                        </button>
                    </div>
                </div>
                <div className="text-center text-[11.5px] text-zinc-500 dark:text-[#A1A1AA] mt-3 font-medium">
                    Commands execute fully offline via local LLM. Ensure Emulator ADB is active before starting.
                </div>
            </div>
        </>
    );
}
