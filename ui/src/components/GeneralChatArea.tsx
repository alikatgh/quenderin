import { useRef, useEffect, useState } from 'react';
import { User, Loader2, Send, MessageSquareText, Cpu, Check, Copy, Mic, FileText, X, Code, PenTool, GraduationCap } from 'lucide-react';
import { LogEntry, RequiredAction } from '../types/index.js';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { Prism as SyntaxHighlighter } from 'react-syntax-highlighter';
import { vscDarkPlus } from 'react-syntax-highlighter/dist/esm/styles/prism';

interface GeneralChatAreaProps {
    logs: LogEntry[];
    status: 'idle' | 'running' | 'done';
    requiredAction: RequiredAction | null;
    onOpenSettings: () => void;
    onOpenTroubleshooter: () => void;
    chatInput: string;
    setChatInput: (val: string) => void;
    onSend: (msg: string, attachments: { name: string, content: string }[]) => void;
    onVoiceStart: () => void;
    onVoiceStop: () => void;
    activePresetId: string;
    onSwitchPreset: (id: string) => void;
}

const PRESET_OPTIONS = [
    { id: 'general', label: 'General', Icon: MessageSquareText },
    { id: 'code-review', label: 'Code Review', Icon: Code },
    { id: 'creative-writer', label: 'Writer', Icon: PenTool },
    { id: 'tutor', label: 'Tutor', Icon: GraduationCap },
    { id: 'summarizer', label: 'Summary', Icon: FileText },
];

function CodeBlock({ children, language, ...props }: any) {
    const [copied, setCopied] = useState(false);

    const handleCopy = () => {
        navigator.clipboard.writeText(String(children).replace(/\n$/, ''));
        setCopied(true);
        setTimeout(() => setCopied(false), 2000);
    };

    return (
        <div className="relative group/code my-6 overflow-hidden rounded-xl border border-white/5 shadow-2xl">
            <div className="flex items-center justify-between px-4 py-2 bg-zinc-900 border-b border-white/5">
                <div className="text-[10px] font-bold text-zinc-500 uppercase tracking-widest">
                    {language || 'code'}
                </div>
                <button
                    onClick={handleCopy}
                    className="flex items-center gap-1.5 px-2 py-1 rounded-md text-[11px] font-medium text-zinc-400 hover:text-white hover:bg-white/10 transition-all"
                >
                    {copied ? (
                        <>
                            <Check className="w-3 h-3 text-emerald-400" />
                            <span className="text-emerald-400">Copied!</span>
                        </>
                    ) : (
                        <>
                            <Copy className="w-3 h-3" />
                            <span>Copy</span>
                        </>
                    )}
                </button>
            </div>
            <SyntaxHighlighter
                {...props}
                children={String(children).replace(/\n$/, '')}
                style={vscDarkPlus}
                language={language}
                PreTag="div"
                className="!bg-[#09090b] !p-4 !m-0 text-sm font-mono leading-relaxed"
                customStyle={{
                    fontFamily: '"JetBrains Mono", Menlo, Monaco, Consolas, monospace',
                }}
            />
        </div>
    );
}

import { AnimatedEntrance } from './AnimatedEntrance.js';

export function GeneralChatArea({ logs, status, requiredAction, onOpenSettings, onOpenTroubleshooter, chatInput, setChatInput, onSend, onVoiceStart, onVoiceStop, activePresetId, onSwitchPreset }: GeneralChatAreaProps) {
    const logsEndRef = useRef<HTMLDivElement>(null);
    const scrollContainerRef = useRef<HTMLDivElement>(null);
    const shouldAutoScrollRef = useRef(true);
    const userScrolledUpAtRef = useRef(0);
    const rafIdRef = useRef(0);
    const textareaRef = useRef<HTMLTextAreaElement>(null);
    const [messageQueue, setMessageQueue] = useState<string[]>([]);
    const [isQueuing, setIsQueuing] = useState(false);
    const [attachments, setAttachments] = useState<{ name: string, content: string }[]>([]);
    const [lastSentPayload, setLastSentPayload] = useState<{ message: string, attachments: { name: string, content: string }[] } | null>(null);
    const [isRecording, setIsRecording] = useState(false);
    const [isDragging, setIsDragging] = useState(false);

    // Filter logs to only show chat events (chat and chat_response) and general status/errors
    const chatLogs = logs.filter(l => ['chat', 'chat_response', 'error'].includes(l.type));
    const lastUserMessage = [...logs].reverse().find((l) => l.type === 'chat')?.message;
    const retryAttachmentCount = lastSentPayload?.attachments?.length ?? 0;

    // Stable key that only changes when log count or last message length changes
    const lastLogKey = chatLogs.length > 0
        ? `${chatLogs.length}-${chatLogs[chatLogs.length - 1]?.message?.length ?? 0}`
        : '';

    // --- Scroll intent detection ---
    useEffect(() => {
        const container = scrollContainerRef.current;
        if (!container) return;

        const onWheel = (e: WheelEvent) => {
            if (e.deltaY < 0) {
                shouldAutoScrollRef.current = false;
                userScrolledUpAtRef.current = Date.now();
            }
        };

        const onTouchMove = () => {
            // Any touch interaction pauses auto-scroll for the cooldown period
            shouldAutoScrollRef.current = false;
            userScrolledUpAtRef.current = Date.now();
        };

        const onScroll = () => {
            // If user recently scrolled up, don't re-engage for 2 seconds
            if (Date.now() - userScrolledUpAtRef.current < 2000) {
                shouldAutoScrollRef.current = false;
                return;
            }
            const gap = container.scrollHeight - container.scrollTop - container.clientHeight;
            shouldAutoScrollRef.current = gap < 30;
        };

        container.addEventListener('wheel', onWheel, { passive: true });
        container.addEventListener('touchmove', onTouchMove, { passive: true });
        container.addEventListener('scroll', onScroll, { passive: true });
        return () => {
            container.removeEventListener('wheel', onWheel);
            container.removeEventListener('touchmove', onTouchMove);
            container.removeEventListener('scroll', onScroll);
        };
    }, []);

    // --- Auto-scroll effect (uses stable key, rAF batched) ---
    useEffect(() => {
        cancelAnimationFrame(rafIdRef.current);
        if (!shouldAutoScrollRef.current) return;
        const container = scrollContainerRef.current;
        if (!container) return;

        rafIdRef.current = requestAnimationFrame(() => {
            if (!shouldAutoScrollRef.current) return; // re-check after frame
            if (status === 'running') {
                container.scrollTop = container.scrollHeight;
            } else {
                container.scrollTo({ top: container.scrollHeight, behavior: 'smooth' });
            }
        });
    }, [lastLogKey, status]);

    useEffect(() => {
        if (textareaRef.current) {
            textareaRef.current.style.height = 'auto';
            textareaRef.current.style.height = Math.min(textareaRef.current.scrollHeight, 250) + 'px';
        }
    }, [chatInput]);

    const handleStart = () => {
        if (chatInput.trim() || attachments.length > 0) {
            if (status === 'running') {
                setMessageQueue(prev => [...prev, chatInput]);
                setChatInput('');
            } else {
                onSend(chatInput, attachments);
                setLastSentPayload({ message: chatInput, attachments: [...attachments] });
                setAttachments([]);
            }
        }
    };

    const handleFileDrop = async (e: React.DragEvent) => {
        e.preventDefault();
        setIsDragging(false);
        const files = Array.from(e.dataTransfer.files);
        for (const file of files) {
            if (file.size > 1024 * 1024) { // 1MB limit for local OCR/Text
                alert(`File ${file.name} is too large. Max 1MB.`);
                continue;
            }
            const content = await file.text();
            setAttachments(prev => [...prev, { name: file.name, content }]);
        }
    };

    const removeAttachment = (index: number) => {
        setAttachments(prev => prev.filter((_, i) => i !== index));
    };

    const startRecording = () => {
        setIsRecording(true);
        onVoiceStart();
    };

    const stopRecording = () => {
        setIsRecording(false);
        onVoiceStop();
    };

    useEffect(() => {
        if (status !== 'running' && messageQueue.length > 0 && !isQueuing) {
            setIsQueuing(true);
            setTimeout(() => {
                const combined = messageQueue.join('\n\n---\n\n');
                setMessageQueue([]);
                setIsQueuing(false);
                onSend(combined, []);
                setLastSentPayload({ message: combined, attachments: [] });
            }, 300); // Small buffer to let state settle
        }
    }, [status, messageQueue, isQueuing, onSend]);

    return (
        <div
            className={`flex-1 flex flex-col relative min-h-0 overflow-hidden ${isDragging ? 'bg-purple-500/5 ring-4 ring-purple-500/20 ring-inset' : ''}`}
            onDragOver={(e) => { e.preventDefault(); setIsDragging(true); }}
            onDragLeave={() => setIsDragging(false)}
            onDrop={handleFileDrop}
        >
            <div ref={scrollContainerRef} className="flex-1 min-h-0 overflow-y-auto px-4 w-full">
                <div className="max-w-[760px] mx-auto pb-40 pt-10">

                    {/* Preset Switcher Bar */}
                    <div className="flex items-center gap-2 mb-6 overflow-x-auto scrollbar-hide">
                        {PRESET_OPTIONS.map((p) => (
                            <button
                                key={p.id}
                                onClick={() => onSwitchPreset(p.id)}
                                className={`flex items-center gap-1.5 px-3 py-1.5 rounded-full text-[12px] font-semibold whitespace-nowrap transition-all border ${
                                    activePresetId === p.id
                                        ? 'bg-purple-50 dark:bg-purple-500/10 border-purple-500 text-purple-700 dark:text-purple-400 ring-1 ring-purple-500/20'
                                        : 'border-zinc-200 dark:border-zinc-700 text-zinc-500 dark:text-zinc-400 hover:border-zinc-300 dark:hover:border-zinc-600 hover:bg-zinc-50 dark:hover:bg-zinc-800'
                                }`}
                            >
                                <p.Icon className="w-3 h-3" />
                                <span>{p.label}</span>
                            </button>
                        ))}
                    </div>

                    {requiredAction?.code === 'OOM_PREVENTION' && (
                        <div className="mb-6 rounded-xl border border-amber-200 dark:border-amber-500/30 bg-amber-50 dark:bg-amber-500/10 p-4 shadow-sm animate-entrance">
                            <p className="text-[13px] font-semibold text-amber-900 dark:text-amber-300 mb-1">Not enough free RAM for current model</p>
                            <p className="text-[13px] text-amber-800 dark:text-amber-200 leading-relaxed">
                                Download a smaller model in the troubleshooter, or disable <span className="font-semibold">Memory Safety</span> in Settings and retry.
                            </p>
                            <div className="mt-3 flex flex-wrap gap-2">
                                <button
                                    onClick={onOpenSettings}
                                    className="px-3 py-1.5 rounded-lg text-[12px] font-semibold bg-amber-600 hover:bg-amber-700 text-white transition-colors"
                                >
                                    Open Settings
                                </button>
                                <button
                                    onClick={onOpenTroubleshooter}
                                    className="px-3 py-1.5 rounded-lg text-[12px] font-semibold border border-amber-300 dark:border-amber-500/40 text-amber-900 dark:text-amber-200 hover:bg-amber-100/70 dark:hover:bg-amber-500/20 transition-colors"
                                >
                                    Open Troubleshooter
                                </button>
                                <button
                                    onClick={() => {
                                        const retryMessage = lastSentPayload?.message || lastUserMessage;
                                        const retryAttachments = lastSentPayload?.attachments || [];
                                        if (!retryMessage) return;
                                        onSend(retryMessage, retryAttachments);
                                    }}
                                    disabled={(!lastSentPayload?.message && !lastUserMessage) || status === 'running'}
                                    className="px-3 py-1.5 rounded-lg text-[12px] font-semibold border border-amber-300 dark:border-amber-500/40 text-amber-900 dark:text-amber-200 hover:bg-amber-100/70 dark:hover:bg-amber-500/20 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                                >
                                    Retry Last Message{retryAttachmentCount > 0 ? ` (${retryAttachmentCount} attachment${retryAttachmentCount > 1 ? 's' : ''})` : ''}
                                </button>
                            </div>
                        </div>
                    )}

                    {chatLogs.length === 0 && (
                        <div className="mt-20 flex flex-col items-center animate-fade-in px-4">
                            <div className="w-16 h-16 bg-white dark:bg-[#27272a] rounded-2xl flex items-center justify-center mb-6 shadow-sm border border-zinc-200 dark:border-[#3f3f46]">
                                <MessageSquareText className="w-8 h-8 text-purple-600 dark:text-purple-400" />
                            </div>
                            <h2 className="text-3xl font-semibold text-zinc-900 dark:text-white mb-2 tracking-tight">General Chat</h2>
                            <p className="text-zinc-500 dark:text-[#a1a1aa] mb-12 text-[15px] text-center max-w-lg leading-relaxed">
                                Talk directly to the local AI assistant. No phone-control features — just fast, private, and fully offline conversation.
                            </p>

                            <div className="grid sm:grid-cols-2 gap-4 w-full">
                                <AnimatedEntrance index={1}>
                                    <div className="p-5 border border-zinc-200 dark:border-[#3f3f46] bg-zinc-50/50 dark:bg-[#27272a]/30 rounded-2xl flex flex-col justify-center hover:bg-zinc-100 dark:hover:bg-[#27272a]/60 hover:translate-y-[-2px] transition-all duration-300 cursor-pointer shadow-sm hover:shadow-md group h-full" onClick={() => { onSend("Write a python script to parse CSV files", []); }}>
                                        <p className="text-[13px] text-zinc-600 dark:text-zinc-400 mb-2 font-medium">Example prompt:</p>
                                        <p className="text-[14px] text-zinc-800 dark:text-zinc-200 font-semibold flex items-center gap-2">
                                            "Write a python script to parse CSV files"
                                        </p>
                                    </div>
                                </AnimatedEntrance>

                                <AnimatedEntrance index={2}>
                                    <div className="p-5 border border-zinc-200 dark:border-[#3f3f46] bg-zinc-50/50 dark:bg-[#27272a]/30 rounded-2xl flex flex-col justify-center hover:bg-zinc-100 dark:hover:bg-[#27272a]/60 hover:translate-y-[-2px] transition-all duration-300 cursor-pointer shadow-sm hover:shadow-md group h-full" onClick={() => { onSend("Explain quantum computing like I'm 5", []); }}>
                                        <p className="text-[13px] text-zinc-600 dark:text-zinc-400 mb-2 font-medium">Example prompt:</p>
                                        <p className="text-[14px] text-zinc-800 dark:text-zinc-200 font-semibold flex items-center gap-2">
                                            "Explain quantum computing like I'm 5"
                                        </p>
                                    </div>
                                </AnimatedEntrance>
                            </div>
                        </div>
                    )}

                    {chatLogs.length > 0 && (
                        <div className="w-full animate-fade-in space-y-8">
                            {chatLogs.map((log) => {
                                if (log.type === 'chat') {
                                    return (
                                        <div key={log.id} className="flex gap-4 sm:gap-6 group animate-entrance">
                                            <div className="w-8 h-8 sm:w-10 sm:h-10 rounded-xl bg-zinc-100 border border-zinc-200 text-zinc-600 dark:bg-[#27272a] dark:border-[#3f3f46] dark:text-zinc-400 flex flex-shrink-0 items-center justify-center shadow-sm">
                                                <User className="w-5 h-5" />
                                            </div>
                                            <div className="flex-1 min-w-0">
                                                <div className="text-[16px] text-zinc-800 dark:text-zinc-200 font-medium leading-relaxed whitespace-pre-wrap">
                                                    {log.message}
                                                </div>
                                            </div>
                                        </div>
                                    )
                                }

                                if (log.type === 'chat_response') {
                                    return (
                                        <div key={log.id} className="flex gap-4 sm:gap-6 bg-zinc-50/50 dark:bg-zinc-800/10 -mx-4 px-4 py-8 rounded-3xl border border-zinc-200/40 dark:border-white/[0.03] hover:border-zinc-300 dark:hover:border-white/10 transition-all duration-300 shadow-sm animate-entrance">
                                            <div className="w-8 h-8 sm:w-10 sm:h-10 rounded-xl bg-purple-100 border border-purple-200 text-purple-600 dark:bg-purple-500/10 dark:border-purple-500/20 dark:text-purple-400 flex flex-shrink-0 items-center justify-center shadow-sm">
                                                <Cpu className="w-5 h-5" />
                                            </div>
                                            <div className="flex-1 min-w-0">
                                                <div className="text-[13px] font-bold text-purple-600/80 dark:text-purple-400/80 mb-1.5 uppercase tracking-wider flex items-center gap-2">
                                                    AI Assistant {log.isStreaming && <span className="flex h-1.5 w-1.5 rounded-full bg-purple-500 animate-pulse" />}
                                                </div>
                                                <div className="text-[16px] text-zinc-800 dark:text-zinc-300 leading-relaxed">
                                                    <div className="markdown-body prose prose-zinc dark:prose-invert max-w-none">
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
                                                        {log.isStreaming && <span className="inline-block w-[2px] h-[1.1em] bg-purple-500 ml-0.5 align-text-bottom animate-pulse" />}
                                                    </div>
                                                </div>
                                                {!log.isStreaming && log.meta && (
                                                    <div className="mt-3 flex items-center gap-3 text-[11px] text-zinc-400 dark:text-zinc-500 font-medium">
                                                        <span>{log.meta.tokensPerSecond} tok/s</span>
                                                        <span className="w-1 h-1 rounded-full bg-zinc-300 dark:bg-zinc-600" />
                                                        <span>{log.meta.tokenCount} tokens</span>
                                                        <span className="w-1 h-1 rounded-full bg-zinc-300 dark:bg-zinc-600" />
                                                        <span>TTFT {log.meta.timeToFirstTokenMs}ms</span>
                                                        <span className="w-1 h-1 rounded-full bg-zinc-300 dark:bg-zinc-600" />
                                                        <span>{(log.meta.durationMs / 1000).toFixed(1)}s total</span>
                                                    </div>
                                                )}
                                            </div>
                                        </div>
                                    )
                                }

                                if (log.type === 'error') {
                                    return (
                                        <div key={log.id} className="bg-red-50 dark:bg-red-500/10 border border-red-200 dark:border-red-500/20 rounded-xl p-4 flex items-start gap-3 mt-4 mb-2 shadow-sm">
                                            <div className="text-[14px] text-red-800 dark:text-red-300 font-medium leading-relaxed prose prose-sm prose-red dark:prose-invert max-w-none [&>p]:mb-2 [&>ol]:mt-2 [&>ul]:mt-2 [&>ol>li]:mb-1 [&>ul>li]:mb-1">
                                                <ReactMarkdown remarkPlugins={[remarkGfm]}>{log.message}</ReactMarkdown>
                                            </div>
                                        </div>
                                    )
                                }

                                return null;
                            })}

                            {status === 'running' && chatLogs.length > 0 && chatLogs[chatLogs.length - 1].type === 'chat' && (
                                <div className="flex gap-4 sm:gap-6">
                                    <div className="w-8 h-8 sm:w-10 sm:h-10 rounded-xl bg-purple-100 border border-purple-200 text-purple-600 dark:bg-purple-500/10 dark:border-purple-500/20 dark:text-purple-400 flex flex-shrink-0 items-center justify-center mt-1">
                                        <Cpu className="w-5 h-5" />
                                    </div>
                                    <div className="flex items-center gap-2 mt-4 text-zinc-500">
                                        <Loader2 className="w-4 h-4 animate-spin" />
                                        <span className="text-[14px]">Generating response...</span>
                                    </div>
                                </div>
                            )}
                        </div>
                    )}
                    {messageQueue.length > 0 && (
                        <div className="w-full mt-6 space-y-4 animate-entrance">
                            {messageQueue.map((msg, i) => (
                                <div key={`queue-${i}`} className="flex gap-4 sm:gap-6 group opacity-50">
                                    <div className="w-8 h-8 sm:w-10 sm:h-10 rounded-xl bg-zinc-100 border border-zinc-200 text-zinc-400 dark:bg-[#27272a] dark:border-[#3f3f46] dark:text-zinc-500 flex flex-shrink-0 items-center justify-center shadow-sm">
                                        <User className="w-5 h-5" />
                                    </div>
                                    <div className="flex-1 min-w-0">
                                        <div className="text-[13px] font-bold text-zinc-400 dark:text-zinc-500 mb-1 uppercase tracking-wider flex items-center gap-2">
                                            Queued for processing <Loader2 className="w-3 h-3 animate-spin" />
                                        </div>
                                        <div className="text-[16px] text-zinc-500 dark:text-zinc-500 font-medium leading-relaxed whitespace-pre-wrap line-clamp-3">
                                            {msg}
                                        </div>
                                    </div>
                                </div>
                            ))}
                        </div>
                    )}
                    <div ref={logsEndRef} className="h-1 mt-4" />
                </div>
            </div>

            <div className="absolute bottom-0 left-0 right-0 bg-gradient-to-t from-white via-white dark:from-[#18181b] dark:via-[#18181b] to-transparent pt-12 pb-6 px-4 pointer-events-none">
                <div className="claude-input-wrapper pointer-events-auto">
                    {attachments.length > 0 && (
                        <div className="flex flex-wrap gap-2 px-4 py-2 mb-2">
                            {attachments.map((file, i) => (
                                <div key={i} className="flex items-center gap-1.5 px-2.5 py-1 rounded-lg bg-zinc-100 dark:bg-zinc-800 border border-zinc-200 dark:border-zinc-700">
                                    <FileText className="w-3.5 h-3.5 text-zinc-500" />
                                    <span className="text-[11px] font-medium text-zinc-700 dark:text-zinc-300 max-w-[120px] truncate">{file.name}</span>
                                    <button onClick={() => removeAttachment(i)} className="p-0.5 hover:bg-zinc-200 dark:hover:bg-zinc-700 rounded transition-colors">
                                        <X className="w-3 h-3 text-zinc-400" />
                                    </button>
                                </div>
                            ))}
                        </div>
                    )}

                    <textarea
                        ref={textareaRef}
                        className="claude-textarea"
                        placeholder={status === 'running' ? "AI is generating... Keep typing to queue up a message." : "Talk to your local model... Drop files to attach."}
                        value={chatInput}
                        onChange={(e) => setChatInput(e.target.value)}
                        disabled={isQueuing}
                        rows={1}
                        onKeyDown={(e) => {
                            if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); handleStart() }
                        }}
                    />
                    <div className="absolute right-3 bottom-2.5 flex items-center gap-2">
                        <button
                            onMouseDown={startRecording}
                            onMouseUp={stopRecording}
                            onMouseLeave={isRecording ? stopRecording : undefined}
                            className={`p-2.5 rounded-xl transition-all duration-300 ${isRecording ? 'bg-red-500 text-white animate-pulse' : 'text-zinc-400 hover:text-zinc-600 dark:text-zinc-500 dark:hover:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800'}`}
                        >
                            <Mic className="w-5 h-5" />
                        </button>
                        <button
                            onClick={handleStart}
                            disabled={isQueuing || (!chatInput.trim() && attachments.length === 0)}
                            className={`p-2.5 rounded-xl transition-all duration-300 flex items-center gap-2 ${(isQueuing || (!chatInput.trim() && attachments.length === 0)) ? 'text-zinc-400 dark:text-zinc-600 bg-transparent' : 'bg-zinc-900 dark:bg-white text-white dark:text-zinc-900 hover:scale-105 active:scale-95 shadow-lg shadow-purple-500/10'}`}
                        >
                            <span className="text-[11px] font-bold uppercase tracking-widest hidden sm:inline-block">{(status === 'running' && chatInput.trim()) ? 'Queue' : ''}</span>
                            {isQueuing ? <Loader2 className="w-5 h-5 animate-spin" /> : <Send className="w-5 h-5" />}
                        </button>
                    </div>
                </div>
                <div className="text-center text-[11px] text-zinc-400 dark:text-zinc-500 mt-4 font-bold tracking-[0.15em] uppercase">
                    Offline Private AI Assistant
                </div>
            </div>
        </div>
    );
}
