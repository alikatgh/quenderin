import { useRef, useEffect, useState } from 'react';
import { User, Loader2, MessageSquareText, Mic, FileText, X, Code, PenTool, GraduationCap, Sparkles, ArrowUpRight, Square } from 'lucide-react';
import { LogEntry, RequiredAction } from '../types/index.js';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { safeMarkdownComponents } from '../lib/markdownComponents.js';
import { AnimatedEntrance } from './AnimatedEntrance.js';

interface GeneralChatAreaProps {
    logs: LogEntry[];
    status: 'idle' | 'running' | 'done';
    requiredAction: RequiredAction | null;
    onOpenSettings: () => void;
    onOpenTroubleshooter: () => void;
    chatInput: string;
    setChatInput: (val: string) => void;
    onSend: (msg: string, attachments: { name: string, content: string }[]) => void;
    onStop: () => void;   // Q-292: cancel the in-flight reply
    onVoiceStart: () => void;
    onVoiceStop: () => void;
    activePresetId: string;
    onSwitchPreset: (id: string) => void;
}

const PRESET_OPTIONS = [
    { id: 'general', label: 'General', Icon: MessageSquareText },
    { id: 'code-review', label: 'Code', Icon: Code },
    { id: 'creative-writer', label: 'Writer', Icon: PenTool },
    { id: 'tutor', label: 'Tutor', Icon: GraduationCap },
    { id: 'summarizer', label: 'Summary', Icon: FileText },
];

const SUGGESTIONS = [
    { text: 'Write a Python script to parse CSV files', icon: Code },
    { text: 'Explain quantum computing simply', icon: GraduationCap },
    { text: 'Draft a professional email template', icon: PenTool },
    { text: 'Summarize the key ideas of stoicism', icon: FileText },
];

/** Strip <tool_call>...</tool_call> XML from rendered text */
const TOOL_CALL_BLOCK_RE = /<tool_call>[\s\S]*?<\/tool_call>\s*/g;
const TOOL_CALL_TRAILING_RE = /<tool_call>[\s\S]*$/;
function stripToolCallXml(text: string): string {
    return text.replace(TOOL_CALL_BLOCK_RE, '').replace(TOOL_CALL_TRAILING_RE, '');
}


export function GeneralChatArea({ logs, status, requiredAction, onOpenSettings, onOpenTroubleshooter, chatInput, setChatInput, onSend, onStop, onVoiceStart, onVoiceStop, activePresetId, onSwitchPreset }: GeneralChatAreaProps) {
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

    const chatLogs = logs.filter(l => ['chat', 'chat_response', 'error'].includes(l.type));
    const lastUserMessage = [...logs].reverse().find((l) => l.type === 'chat')?.message;
    const retryAttachmentCount = lastSentPayload?.attachments?.length ?? 0;

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
            shouldAutoScrollRef.current = false;
            userScrolledUpAtRef.current = Date.now();
        };

        const onScroll = () => {
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

    // --- Auto-scroll ---
    useEffect(() => {
        cancelAnimationFrame(rafIdRef.current);
        if (!shouldAutoScrollRef.current) return;
        const container = scrollContainerRef.current;
        if (!container) return;

        rafIdRef.current = requestAnimationFrame(() => {
            if (!shouldAutoScrollRef.current) return;
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
            if (file.size > 1024 * 1024) {
                alert(`File ${file.name} is too large. Max 1MB.`);
                continue;
            }
            // Read each file defensively — a reject (e.g. a dropped directory) must not abort the
            // whole loop or surface as an unhandled rejection; skip the bad one and keep going.
            try {
                const content = await file.text();
                setAttachments(prev => [...prev, { name: file.name, content }]);
            } catch {
                alert(`Could not read ${file.name} — skipping it.`);
            }
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
            }, 300);
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
                <div className="max-w-[760px] mx-auto pb-44 pt-6">

                    {requiredAction?.code === 'OOM_PREVENTION' && (
                        <div className="mb-6 rounded-2xl border border-amber-200/80 dark:border-amber-500/20 bg-amber-50/80 dark:bg-amber-500/5 p-4 animate-entrance">
                            <p className="text-[13px] font-semibold text-amber-900 dark:text-amber-300 mb-1">Not enough free RAM for current model</p>
                            <p className="text-[13px] text-amber-800/80 dark:text-amber-200/70 leading-relaxed">
                                Try a smaller model or disable Memory Safety in Settings.
                            </p>
                            <div className="mt-3 flex flex-wrap gap-2">
                                <button onClick={onOpenSettings} className="px-3 py-1.5 rounded-lg text-[12px] font-semibold bg-amber-600 hover:bg-amber-700 text-white transition-colors">
                                    Settings
                                </button>
                                <button onClick={onOpenTroubleshooter} className="px-3 py-1.5 rounded-lg text-[12px] font-semibold border border-amber-300 dark:border-amber-500/30 text-amber-900 dark:text-amber-200 hover:bg-amber-100/50 dark:hover:bg-amber-500/10 transition-colors">
                                    Troubleshooter
                                </button>
                                <button
                                    onClick={() => {
                                        const retryMessage = lastSentPayload?.message || lastUserMessage;
                                        const retryAttachments = lastSentPayload?.attachments || [];
                                        if (!retryMessage) return;
                                        onSend(retryMessage, retryAttachments);
                                    }}
                                    disabled={(!lastSentPayload?.message && !lastUserMessage) || status === 'running'}
                                    className="px-3 py-1.5 rounded-lg text-[12px] font-semibold border border-amber-300 dark:border-amber-500/30 text-amber-900 dark:text-amber-200 hover:bg-amber-100/50 dark:hover:bg-amber-500/10 transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
                                >
                                    Retry{retryAttachmentCount > 0 ? ` (${retryAttachmentCount} file${retryAttachmentCount > 1 ? 's' : ''})` : ''}
                                </button>
                            </div>
                        </div>
                    )}

                    {/* ── Empty state ── */}
                    {chatLogs.length === 0 && (
                        <div className="mt-16 sm:mt-24 flex flex-col items-center animate-fade-in px-2">
                            <Sparkles className="w-7 h-7 text-purple-500 dark:text-purple-400 mb-5" />
                            <h2 className="text-[22px] sm:text-[26px] font-semibold text-zinc-900 dark:text-white mb-2 tracking-tight text-center">What can I help you with?</h2>
                            <p className="text-zinc-500 dark:text-zinc-400 mb-10 text-[14px] text-center max-w-md leading-relaxed">
                                Everything runs locally on your machine. Private, offline, yours.
                            </p>

                            <div className="grid grid-cols-1 sm:grid-cols-2 gap-2.5 w-full max-w-lg">
                                {SUGGESTIONS.map((s, i) => (
                                    <AnimatedEntrance key={i} index={i}>
                                        <button
                                            onClick={() => onSend(s.text, [])}
                                            className="w-full text-left p-3.5 border border-zinc-200/70 dark:border-zinc-800/70 bg-white/60 dark:bg-zinc-900/40 rounded-xl hover:bg-zinc-50 dark:hover:bg-zinc-800/60 hover:border-zinc-300 dark:hover:border-zinc-700 transition-all duration-200 group"
                                        >
                                            <div className="flex items-start gap-3">
                                                <s.icon className="w-4 h-4 text-zinc-400 dark:text-zinc-500 mt-0.5 flex-shrink-0 group-hover:text-purple-500 dark:group-hover:text-purple-400 transition-colors" />
                                                <span className="text-[13px] text-zinc-600 dark:text-zinc-300 leading-snug">{s.text}</span>
                                            </div>
                                        </button>
                                    </AnimatedEntrance>
                                ))}
                            </div>
                        </div>
                    )}

                    {/* ── Messages ── */}
                    {chatLogs.length > 0 && (
                        <div className="w-full space-y-1">
                            {chatLogs.map((log) => {
                                if (log.type === 'chat') {
                                    return (
                                        <div key={log.id} className="py-5 animate-entrance">
                                            <div className="flex gap-3.5">
                                                <div className="w-7 h-7 rounded-full bg-zinc-200 dark:bg-zinc-700 flex flex-shrink-0 items-center justify-center mt-0.5">
                                                    <User className="w-3.5 h-3.5 text-zinc-600 dark:text-zinc-300" />
                                                </div>
                                                <div className="flex-1 min-w-0 pt-0.5">
                                                    <div className="text-[15px] text-zinc-900 dark:text-zinc-100 leading-7 whitespace-pre-wrap">
                                                        {log.message}
                                                    </div>
                                                </div>
                                            </div>
                                        </div>
                                    );
                                }

                                if (log.type === 'chat_response') {
                                    return (
                                        <div key={log.id} className="py-5 animate-entrance">
                                            <div className="flex gap-3.5">
                                                <div className="w-7 h-7 rounded-full bg-purple-100 dark:bg-purple-500/15 flex flex-shrink-0 items-center justify-center mt-0.5">
                                                    <Sparkles className="w-3.5 h-3.5 text-purple-600 dark:text-purple-400" />
                                                </div>
                                                <div className="flex-1 min-w-0 pt-0.5">
                                                    <div className="text-[15px] text-zinc-800 dark:text-zinc-200 leading-7">
                                                        <div className="markdown-body prose prose-zinc dark:prose-invert max-w-none prose-p:my-2 prose-headings:mt-5 prose-headings:mb-2 prose-li:my-0.5 prose-ul:my-2 prose-ol:my-2">
                                                            <ReactMarkdown
                                                                remarkPlugins={[remarkGfm]}
                                                                components={safeMarkdownComponents}
                                                            >
                                                                {stripToolCallXml(log.message)}
                                                            </ReactMarkdown>
                                                            {log.isStreaming && <span className="inline-block w-[2px] h-[1.1em] bg-purple-500 ml-0.5 align-text-bottom animate-pulse" />}
                                                        </div>
                                                    </div>
                                                    {!log.isStreaming && log.meta && (
                                                        <div className="mt-3 flex items-center gap-2.5 text-[11px] tabular-nums text-zinc-400 dark:text-zinc-500">
                                                            <span>{log.meta.tokensPerSecond} tok/s</span>
                                                            <span className="text-zinc-300 dark:text-zinc-700">&middot;</span>
                                                            <span>{log.meta.tokenCount} tokens</span>
                                                            <span className="text-zinc-300 dark:text-zinc-700">&middot;</span>
                                                            <span>{(log.meta.durationMs / 1000).toFixed(1)}s</span>
                                                        </div>
                                                    )}
                                                </div>
                                            </div>
                                        </div>
                                    );
                                }

                                if (log.type === 'error') {
                                    return (
                                        <div key={log.id} className="py-3">
                                            <div className="bg-red-50 dark:bg-red-500/5 border border-red-200/70 dark:border-red-500/15 rounded-xl p-4 shadow-sm">
                                                <div className="text-[14px] text-red-800 dark:text-red-300 leading-relaxed prose prose-sm prose-red dark:prose-invert max-w-none [&>p]:mb-2 [&>ol]:mt-2 [&>ul]:mt-2 [&>ol>li]:mb-1 [&>ul>li]:mb-1">
                                                    <ReactMarkdown remarkPlugins={[remarkGfm]} components={safeMarkdownComponents}>{log.message}</ReactMarkdown>
                                                </div>
                                            </div>
                                        </div>
                                    );
                                }

                                return null;
                            })}

                            {status === 'running' && chatLogs.length > 0 && chatLogs[chatLogs.length - 1].type === 'chat' && (
                                <div className="py-5">
                                    <div className="flex gap-3.5">
                                        <div className="w-7 h-7 rounded-full bg-purple-100 dark:bg-purple-500/15 flex flex-shrink-0 items-center justify-center mt-0.5">
                                            <Sparkles className="w-3.5 h-3.5 text-purple-600 dark:text-purple-400" />
                                        </div>
                                        <div className="flex items-center gap-2 pt-1.5">
                                            <div className="flex gap-1">
                                                <span className="w-1.5 h-1.5 rounded-full bg-purple-400 dark:bg-purple-500 animate-bounce" style={{ animationDelay: '0ms' }} />
                                                <span className="w-1.5 h-1.5 rounded-full bg-purple-400 dark:bg-purple-500 animate-bounce" style={{ animationDelay: '150ms' }} />
                                                <span className="w-1.5 h-1.5 rounded-full bg-purple-400 dark:bg-purple-500 animate-bounce" style={{ animationDelay: '300ms' }} />
                                            </div>
                                        </div>
                                    </div>
                                </div>
                            )}
                        </div>
                    )}

                    {messageQueue.length > 0 && (
                        <div className="w-full mt-2 space-y-1">
                            {messageQueue.map((msg, i) => (
                                <div key={`queue-${i}`} className="py-4 opacity-40">
                                    <div className="flex gap-3.5">
                                        <div className="w-7 h-7 rounded-full bg-zinc-200 dark:bg-zinc-700 flex flex-shrink-0 items-center justify-center mt-0.5">
                                            <User className="w-3.5 h-3.5 text-zinc-400 dark:text-zinc-500" />
                                        </div>
                                        <div className="flex-1 min-w-0 pt-0.5">
                                            <p className="text-[11px] text-zinc-400 dark:text-zinc-500 font-medium mb-1 flex items-center gap-1.5">
                                                Queued <Loader2 className="w-3 h-3 animate-spin" />
                                            </p>
                                            <div className="text-[15px] text-zinc-500 leading-7 whitespace-pre-wrap line-clamp-3">
                                                {msg}
                                            </div>
                                        </div>
                                    </div>
                                </div>
                            ))}
                        </div>
                    )}
                    <div ref={logsEndRef} className="h-1 mt-4" />
                </div>
            </div>

            {/* ── Composer ── */}
            <div className="absolute bottom-0 left-0 right-0 bg-gradient-to-t from-white via-white/95 dark:from-[#18181b] dark:via-[#18181b]/95 to-transparent pt-8 pb-4 px-4 pointer-events-none">
                <div className="max-w-3xl mx-auto pointer-events-auto">
                    {/* Preset chips — compact row above input */}
                    <div className="flex items-center gap-1 mb-2 px-1 overflow-x-auto scrollbar-hide">
                        {PRESET_OPTIONS.map((p) => (
                            <button
                                key={p.id}
                                onClick={() => onSwitchPreset(p.id)}
                                className={`flex items-center gap-1 px-2.5 py-1 rounded-lg text-[11px] font-medium whitespace-nowrap transition-all ${
                                    activePresetId === p.id
                                        ? 'bg-purple-100 dark:bg-purple-500/15 text-purple-700 dark:text-purple-400'
                                        : 'text-zinc-400 dark:text-zinc-500 hover:text-zinc-600 dark:hover:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800'
                                }`}
                            >
                                <p.Icon className="w-3 h-3" />
                                <span>{p.label}</span>
                            </button>
                        ))}
                    </div>

                    <div className="chat-input-wrapper">
                        {attachments.length > 0 && (
                            <div className="flex flex-wrap gap-1.5 px-3.5 pt-3 pb-0">
                                {attachments.map((file, i) => (
                                    <div key={i} className="flex items-center gap-1.5 px-2 py-1 rounded-lg bg-zinc-100 dark:bg-zinc-800 border border-zinc-200/70 dark:border-zinc-700/70 text-[11px]">
                                        <FileText className="w-3 h-3 text-zinc-400" />
                                        <span className="font-medium text-zinc-600 dark:text-zinc-300 max-w-[100px] truncate">{file.name}</span>
                                        <button type="button" aria-label={`Remove ${file.name}`} onClick={() => removeAttachment(i)} className="p-0.5 hover:bg-zinc-200 dark:hover:bg-zinc-700 rounded transition-colors">
                                            <X className="w-3 h-3 text-zinc-400" />
                                        </button>
                                    </div>
                                ))}
                            </div>
                        )}

                        <textarea
                            ref={textareaRef}
                            className="chat-textarea"
                            placeholder={status === 'running' ? "AI is thinking... type to queue a follow-up" : "Ask anything..."}
                            value={chatInput}
                            onChange={(e) => setChatInput(e.target.value)}
                            disabled={isQueuing}
                            rows={1}
                            onKeyDown={(e) => {
                                if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); handleStart() }
                            }}
                        />
                        <div className="absolute right-2 bottom-2 flex items-center gap-1">
                            <button
                                type="button"
                                aria-label={isRecording ? 'Stop voice recording' : 'Start voice recording'}
                                aria-pressed={isRecording}
                                // Q-318: Pointer events (not mouse-only) so press-and-hold to talk works on
                                // TOUCH devices too — a tap/hold never fires onMouseDown reliably. Matches
                                // the agent view's ChatArea, which already uses pointer events.
                                onPointerDown={startRecording}
                                onPointerUp={stopRecording}
                                onPointerLeave={isRecording ? stopRecording : undefined}
                                className={`p-2 rounded-lg transition-all ${isRecording ? 'bg-red-500 text-white animate-pulse' : 'text-zinc-400 hover:text-zinc-600 dark:text-zinc-500 dark:hover:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800'}`}
                            >
                                <Mic className="w-4.5 h-4.5" />
                            </button>
                            {status === 'running' ? (
                                /* Q-292: while a reply streams the primary button STOPS it (the partial
                                   stays in the transcript). Follow-ups can still be queued with Enter. */
                                <button
                                    type="button"
                                    aria-label="Stop generating"
                                    onClick={onStop}
                                    className="p-2 rounded-lg transition-all bg-zinc-900 dark:bg-zinc-100 text-white dark:text-zinc-900 hover:bg-zinc-800 dark:hover:bg-white active:scale-95 shadow-sm"
                                >
                                    <Square className="w-4 h-4" fill="currentColor" />
                                </button>
                            ) : (
                                <button
                                    type="button"
                                    aria-label={isQueuing ? 'Queuing message' : 'Send message'}
                                    onClick={handleStart}
                                    disabled={isQueuing || (!chatInput.trim() && attachments.length === 0)}
                                    className={`p-2 rounded-lg transition-all ${(isQueuing || (!chatInput.trim() && attachments.length === 0)) ? 'text-zinc-300 dark:text-zinc-600' : 'bg-zinc-900 dark:bg-zinc-100 text-white dark:text-zinc-900 hover:bg-zinc-800 dark:hover:bg-white active:scale-95 shadow-sm'}`}
                                >
                                    {isQueuing ? <Loader2 className="w-4.5 h-4.5 animate-spin" /> : <ArrowUpRight className="w-4.5 h-4.5" />}
                                </button>
                            )}
                        </div>
                    </div>

                    <p className="text-center text-[10px] text-zinc-400 dark:text-zinc-600 mt-2.5 font-medium tracking-wide">
                        Fully offline &middot; Private &middot; Local AI
                    </p>
                </div>
            </div>
        </div>
    );
}
