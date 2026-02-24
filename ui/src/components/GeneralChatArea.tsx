import { useRef, useEffect } from 'react';
import { User, Loader2, Send, MessageSquareText, Cpu } from 'lucide-react';
import { LogEntry } from '../types/index.js';

interface GeneralChatAreaProps {
    logs: LogEntry[];
    status: 'idle' | 'running' | 'done';
    chatInput: string;
    setChatInput: (val: string) => void;
    onSend: (msg: string) => void;
}

export function GeneralChatArea({ logs, status, chatInput, setChatInput, onSend }: GeneralChatAreaProps) {
    const logsEndRef = useRef<HTMLDivElement>(null);
    const textareaRef = useRef<HTMLTextAreaElement>(null);

    // Filter logs to only show chat events (chat and chat_response) and general status/errors
    const chatLogs = logs.filter(l => ['chat', 'chat_response', 'error'].includes(l.type));

    useEffect(() => {
        if (logsEndRef.current) {
            logsEndRef.current.scrollIntoView({ behavior: 'smooth' });
        }
    }, [chatLogs]);

    useEffect(() => {
        if (textareaRef.current) {
            textareaRef.current.style.height = 'auto';
            textareaRef.current.style.height = Math.min(textareaRef.current.scrollHeight, 200) + 'px';
        }
    }, [chatInput]);

    const handleStart = () => {
        if (chatInput.trim()) {
            onSend(chatInput);
        }
    };

    return (
        <>
            <div className="flex-1 overflow-y-auto px-4 w-full">
                <div className="max-w-[760px] mx-auto pb-40 pt-10">

                    {chatLogs.length === 0 && (
                        <div className="mt-20 flex flex-col items-center animate-fade-in px-4">
                            <div className="w-16 h-16 bg-white dark:bg-[#27272a] rounded-2xl flex items-center justify-center mb-6 shadow-sm border border-zinc-200 dark:border-[#3f3f46]">
                                <MessageSquareText className="w-8 h-8 text-purple-600 dark:text-purple-400" />
                            </div>
                            <h2 className="text-3xl font-medium text-zinc-900 dark:text-white mb-2 tracking-tight">General Chat</h2>
                            <p className="text-zinc-500 dark:text-[#a1a1aa] mb-12 text-[15px] text-center max-w-lg">
                                Talk directly to the local foundational model without triggering spatial agent capabilities. Fast, private, and fully offline.
                            </p>

                            <div className="grid sm:grid-cols-2 gap-4 w-full">
                                <div className="p-5 border border-zinc-200 dark:border-[#3f3f46] bg-zinc-50/50 dark:bg-[#27272a]/30 rounded-2xl flex flex-col justify-center hover:bg-zinc-100 dark:hover:bg-[#27272a]/60 transition-colors cursor-pointer" onClick={() => { setChatInput("Write a python script to parse CSV files"); }}>
                                    <p className="text-[13px] text-zinc-600 dark:text-zinc-400 mb-2">Example prompt:</p>
                                    <p className="text-[14px] text-zinc-800 dark:text-zinc-200 font-medium flex items-center gap-2 group">
                                        "Write a python script to parse CSV files"
                                    </p>
                                </div>

                                <div className="p-5 border border-zinc-200 dark:border-[#3f3f46] bg-zinc-50/50 dark:bg-[#27272a]/30 rounded-2xl flex flex-col justify-center hover:bg-zinc-100 dark:hover:bg-[#27272a]/60 transition-colors cursor-pointer" onClick={() => { setChatInput("Explain quantum computing like I'm 5"); }}>
                                    <p className="text-[13px] text-zinc-600 dark:text-zinc-400 mb-2">Example prompt:</p>
                                    <p className="text-[14px] text-zinc-800 dark:text-zinc-200 font-medium flex items-center gap-2 group">
                                        "Explain quantum computing like I'm 5"
                                    </p>
                                </div>
                            </div>
                        </div>
                    )}

                    {chatLogs.length > 0 && (
                        <div className="w-full animate-fade-in space-y-8">
                            {chatLogs.map((log) => {
                                if (log.type === 'chat') {
                                    return (
                                        <div key={log.id} className="flex justify-end">
                                            <div className="max-w-[85%] bg-zinc-100 dark:bg-[#27272a] border border-zinc-200 dark:border-[#3f3f46] px-5 py-4 rounded-2xl rounded-tr-sm">
                                                <div className="flex items-center gap-2 mb-1 justify-end">
                                                    <span className="text-xs font-medium text-zinc-500 dark:text-zinc-400">You</span>
                                                    <User className="w-3.5 h-3.5 text-zinc-600 dark:text-zinc-500" />
                                                </div>
                                                <div className="text-[16px] text-zinc-900 dark:text-zinc-100 leading-relaxed font-medium whitespace-pre-wrap">
                                                    {log.message}
                                                </div>
                                            </div>
                                        </div>
                                    )
                                }

                                if (log.type === 'chat_response') {
                                    return (
                                        <div key={log.id} className="flex gap-4 sm:gap-6">
                                            <div className="w-8 h-8 sm:w-10 sm:h-10 rounded-xl bg-purple-100 border border-purple-200 text-purple-600 dark:bg-purple-500/10 dark:border-purple-500/20 dark:text-purple-400 flex flex-shrink-0 items-center justify-center mt-1">
                                                <Cpu className="w-5 h-5" />
                                            </div>
                                            <div className="flex-1 min-w-0 bg-white dark:bg-[#18181b] p-2 mt-[-4px]">
                                                <div className="text-xs font-medium text-zinc-500 dark:text-zinc-400 mb-2 ml-1">Llama-3-Instruct</div>
                                                <div className="text-[15px] text-zinc-800 dark:text-zinc-200 leading-relaxed whitespace-pre-wrap font-serif">
                                                    {log.message}
                                                </div>
                                            </div>
                                        </div>
                                    )
                                }

                                if (log.type === 'error') {
                                    return (
                                        <div key={log.id} className="bg-red-50 dark:bg-red-500/10 border border-red-200 dark:border-red-500/20 rounded-xl p-4 flex items-start gap-3 mt-4 mb-2 shadow-sm">
                                            <div className="text-[14px] text-red-800 dark:text-red-300 font-medium leading-relaxed whitespace-pre-wrap">
                                                {log.message}
                                            </div>
                                        </div>
                                    )
                                }
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
                    <div ref={logsEndRef} className="h-1" />
                </div>
            </div>

            <div className="absolute bottom-0 left-0 right-0 bg-gradient-to-t from-white via-white dark:from-[#18181b] dark:via-[#18181b] to-transparent pt-12 pb-6 px-4 pointer-events-none">
                <div className="claude-input-wrapper pointer-events-auto">
                    <textarea
                        ref={textareaRef}
                        className="claude-textarea"
                        placeholder="Talk to your local model..."
                        value={chatInput}
                        onChange={(e) => setChatInput(e.target.value)}
                        disabled={status === 'running'}
                        rows={1}
                        onKeyDown={(e) => {
                            if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); handleStart() }
                        }}
                    />
                    <div className="absolute right-2.5 bottom-2.5">
                        <button
                            onClick={handleStart}
                            disabled={status === 'running' || !chatInput.trim()}
                            className={`p-1.5 rounded-lg transition-colors ${(status === 'running' || !chatInput.trim()) ? 'text-zinc-400 dark:text-zinc-600 bg-transparent' : 'bg-black dark:bg-white text-white dark:text-black hover:bg-zinc-800 dark:hover:bg-zinc-200'}`}
                        >
                            {status === 'running' ? <Loader2 className="w-[18px] h-[18px] animate-spin" /> : <Send className="w-[18px] h-[18px] ml-0.5" />}
                        </button>
                    </div>
                </div>
                <div className="text-center text-[11.5px] text-zinc-500 dark:text-[#A1A1AA] mt-3 font-medium">
                    Conversations happen entirely offline.
                </div>
            </div>
        </>
    );
}
