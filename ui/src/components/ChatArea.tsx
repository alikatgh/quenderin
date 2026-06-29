import { useRef, useEffect, useState } from 'react';
import { Sparkles, BookOpen, ArrowRight, User, AlertCircle, Activity, Eye, BrainCircuit, Zap, CheckCircle2, ArrowUpRight, Mic } from 'lucide-react';
import { LogEntry } from '../types/index.js';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { CodeBlock } from './CodeBlock.js';

interface ChatAreaProps {
    logs: LogEntry[];
    status: 'idle' | 'running' | 'done';
    goal: string;
    setGoal: (goal: string) => void;
    onStart: (goal: string, attachments?: { name: string, content: string }[]) => void;
    setCurrentView: (view: 'chat' | 'docs') => void;
    onVoiceStart: () => void;
    onVoiceStop: () => void;
}

interface GoalTemplate { id: string; category: string; label: string; template: string; }

export function ChatArea({ logs, status, goal, setGoal, onStart, setCurrentView, onVoiceStart, onVoiceStop }: ChatAreaProps) {
    const logsEndRef = useRef<HTMLDivElement>(null);
    const textareaRef = useRef<HTMLTextAreaElement>(null);
    const [isRecording, setIsRecording] = useState(false);
    const [templates, setTemplates] = useState<GoalTemplate[]>([]);

    useEffect(() => {
        fetch('/api/templates')
            .then(r => r.ok ? r.json() : null)
            .then(d => { if (d?.templates) setTemplates(d.templates); })
            .catch(() => {});
    }, []);

    // Filter to only agent-type logs — ignore chat entries from General Chat
    const agentLogs = logs.filter(l => ['status', 'observe', 'decide', 'action', 'error', 'done'].includes(l.type));

    useEffect(() => {
        if (logsEndRef.current) {
            logsEndRef.current.scrollIntoView({ behavior: 'smooth' });
        }
        // Depend on STABLE primitives (count + last-entry id), not the freshly-filtered `agentLogs`
        // array reference (a new array every render) — which fired a scroll on every render (opus backlog).
    }, [agentLogs.length, agentLogs.at(-1)?.id]);

    useEffect(() => {
        if (textareaRef.current) {
            textareaRef.current.style.height = 'auto';
            textareaRef.current.style.height = Math.min(textareaRef.current.scrollHeight, 250) + 'px';
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
            <div className="flex-1 min-h-0 overflow-y-auto px-4 w-full">
                <div className="max-w-[760px] mx-auto pb-40">

                    {agentLogs.length === 0 && (
                        <div className="mt-[20vh] flex flex-col items-center animate-fade-in px-4">
                            <h2 className="text-2xl font-semibold text-zinc-800 dark:text-zinc-200 mb-2 tracking-tight">What should I automate?</h2>
                            <p className="text-zinc-400 dark:text-zinc-500 mb-10 text-[14px]">Describe a task and I'll control the device for you.</p>

                            <div className="grid sm:grid-cols-2 gap-2.5 w-full max-w-lg">
                                <button
                                    onClick={() => setCurrentView('docs')}
                                    className="text-left p-3.5 border border-zinc-200/80 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 rounded-xl hover:bg-zinc-50 dark:hover:bg-zinc-800/60 hover:border-zinc-300 dark:hover:border-zinc-700 transition-all col-span-full group"
                                >
                                    <div className="flex items-center gap-2">
                                        <BookOpen className="w-4 h-4 text-zinc-400" />
                                        <span className="text-[13px] font-medium text-zinc-700 dark:text-zinc-300">Read documentation</span>
                                        <ArrowRight className="w-3 h-3 text-zinc-300 dark:text-zinc-600 ml-auto group-hover:text-purple-500 transition-colors" />
                                    </div>
                                </button>

                                {templates.map(t => (
                                    <button
                                        key={t.id}
                                        onClick={() => setGoal(t.template)}
                                        className="text-left p-3.5 border border-zinc-200/80 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 rounded-xl hover:bg-zinc-50 dark:hover:bg-zinc-800/60 hover:border-zinc-300 dark:hover:border-zinc-700 transition-all group"
                                    >
                                        <p className="text-[13px] font-medium text-zinc-700 dark:text-zinc-300">{t.label}</p>
                                        <p className="text-[11px] text-zinc-400 dark:text-zinc-500 mt-0.5 truncate">{t.template}</p>
                                    </button>
                                ))}

                                {templates.length === 0 && (
                                    <div className="col-span-full p-3.5 border border-zinc-200/80 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 rounded-xl">
                                        <p className="text-[13px] text-zinc-400 dark:text-zinc-500">Try: "Open Settings and turn on WiFi"</p>
                                    </div>
                                )}
                            </div>
                        </div>
                    )}

                    {agentLogs.length > 0 && (
                        <div className="mt-8 mb-8 w-full animate-fade-in">
                            <div className="flex gap-3 mb-6">
                                <div className="w-7 h-7 rounded-full bg-zinc-100 dark:bg-zinc-800 text-zinc-500 dark:text-zinc-400 flex flex-shrink-0 items-center justify-center">
                                    <User className="w-4 h-4" />
                                </div>
                                <div className="flex-1 min-w-0 pt-0.5">
                                    <div className="text-[15px] text-zinc-800 dark:text-zinc-200 leading-relaxed whitespace-pre-wrap">
                                        {agentLogs[0]?.message.replace('Goal set: ', '')}
                                    </div>
                                </div>
                            </div>

                            <div className="flex gap-3">
                                <div className="w-7 h-7 rounded-full bg-purple-100 dark:bg-purple-500/10 text-purple-600 dark:text-purple-400 flex flex-shrink-0 items-center justify-center">
                                    <Sparkles className="w-4 h-4" />
                                </div>

                                <div className="flex-1 min-w-0 pt-0.5">
                                    <div className="space-y-3">
                                        {agentLogs.slice(1).map((log) => (
                                            <div key={log.id} className="animate-fade-in">
                                                {log.type === 'error' ? (
                                                    <div className="bg-red-50 dark:bg-red-500/10 border border-red-200 dark:border-red-500/20 rounded-xl p-4 flex items-start gap-3 mt-4 mb-2 shadow-sm">
                                                        <AlertCircle className="w-5 h-5 text-red-600 dark:text-red-400 flex-shrink-0 mt-0.5" />
                                                        <div className="text-[14px] text-red-800 dark:text-red-300 font-medium leading-relaxed prose prose-sm prose-red dark:prose-invert max-w-none [&>p]:mb-2 [&>ol]:mt-2 [&>ul]:mt-2 [&>ol>li]:mb-1 [&>ul>li]:mb-1">
                                                            <ReactMarkdown
                                                                remarkPlugins={[remarkGfm]}
                                                                components={{
                                                                    code({ node, inline, className, children, ...props }: any) {
                                                                        const match = /language-(\w+)/.exec(className || '')
                                                                        return (!inline && match) ? (
                                                                            <CodeBlock
                                                                                {...props}
                                                                                language={match[1]}
                                                                                children={children}
                                                                            />
                                                                        ) : (
                                                                            <code {...props} className={`${className} bg-zinc-100 dark:bg-white/10 px-1.5 py-0.5 rounded text-sm font-medium`}>
                                                                                {children}
                                                                            </code>
                                                                        )
                                                                    }
                                                                }}
                                                            >
                                                                {log.message}
                                                            </ReactMarkdown>
                                                        </div>
                                                    </div>
                                                ) : (
                                                    <div className="flex items-start gap-3 w-full">
                                                        <div className="mt-[2px] opacity-70 flex-shrink-0">{getTypeIcon(log.type)}</div>
                                                        <div className={`markdown-body w-full break-words min-w-0 ${log.type === 'done' ? 'text-zinc-900 dark:text-zinc-100 font-medium' : 'text-zinc-700 dark:text-zinc-300'}`}>
                                                            {log.type === 'decide' ? (
                                                                <div className="flex items-center flex-wrap gap-2 text-[14px] text-zinc-700 dark:text-zinc-300">
                                                                    <span>Plan generated:</span>
                                                                    <code className="bg-zinc-100 dark:bg-zinc-800 font-mono tracking-tight text-[13px] px-1.5 py-0.5 rounded border border-zinc-200 dark:border-zinc-700">{log.command}</code>
                                                                </div>
                                                            ) : (
                                                                <span>{log.message || "Working..."}</span>
                                                            )}
                                                        </div>
                                                    </div>
                                                )}
                                            </div>
                                        ))}

                                        {status === 'running' && (
                                            <div className="flex items-center gap-1.5 mt-2">
                                                <div className="w-1.5 h-1.5 rounded-full bg-zinc-400 dark:bg-zinc-500 animate-bounce [animation-delay:0ms]" />
                                                <div className="w-1.5 h-1.5 rounded-full bg-zinc-400 dark:bg-zinc-500 animate-bounce [animation-delay:150ms]" />
                                                <div className="w-1.5 h-1.5 rounded-full bg-zinc-400 dark:bg-zinc-500 animate-bounce [animation-delay:300ms]" />
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
                    <div className="absolute right-3 bottom-2.5 flex items-center gap-2">
                        <button
                            type="button"
                            aria-label={isRecording ? 'Stop voice recording' : 'Start voice recording'}
                            aria-pressed={isRecording}
                            onMouseDown={() => { setIsRecording(true); onVoiceStart() }}
                            onMouseUp={() => { setIsRecording(false); onVoiceStop() }}
                            onMouseLeave={() => { if (isRecording) { setIsRecording(false); onVoiceStop() } }}
                            className={`p-2 rounded-xl transition-all ${isRecording ? 'bg-red-500 text-white animate-pulse' : 'text-zinc-400 hover:text-zinc-600 dark:text-zinc-500 dark:hover:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800'}`}
                        >
                            <Mic className="w-[18px] h-[18px]" />
                        </button>
                        <button
                            type="button"
                            aria-label="Run agent goal"
                            onClick={handleStart}
                            disabled={status === 'running' || !goal.trim()}
                            className={`p-2 rounded-xl transition-all ${(status === 'running' || !goal.trim()) ? 'text-zinc-300 dark:text-zinc-600 bg-transparent' : 'bg-zinc-900 dark:bg-white text-white dark:text-zinc-900 hover:scale-105 active:scale-95'}`}
                        >
                            {status === 'running' ? <Activity className="w-[18px] h-[18px] animate-spin" /> : <ArrowUpRight className="w-[18px] h-[18px]" />}
                        </button>
                    </div>
                </div>
                <p className="text-center text-[11px] text-zinc-400 dark:text-zinc-500 mt-2.5">
                    Runs offline on your device. Connect your phone before starting.
                </p>
            </div>
        </>
    );
}
