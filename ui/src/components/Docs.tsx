
import { BookOpen, Sparkles, ArrowLeft } from 'lucide-react';

interface DocsProps {
    onBack: () => void;
}

export function Docs({ onBack }: DocsProps) {
    return (
        <div className="flex-1 overflow-y-auto px-4 w-full">
            <div className="max-w-[760px] mx-auto py-12 pb-32">
                <button
                    onClick={onBack}
                    className="mb-8 flex items-center gap-2 text-sm font-medium text-zinc-500 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-200 transition-colors"
                >
                    <ArrowLeft className="w-4 h-4" /> Back to Agent Console
                </button>

                <div className="flex items-center gap-3 mb-8">
                    <BookOpen className="w-8 h-8 text-purple-600 dark:text-purple-400" />
                    <h1 className="text-3xl font-semibold text-zinc-900 dark:text-zinc-100 tracking-tight">Quenderin Documentation</h1>
                </div>

                <div className="space-y-12 text-[15px] leading-relaxed text-zinc-700 dark:text-zinc-300">
                    <section>
                        <h3 className="text-xl font-semibold text-zinc-900 dark:text-white mb-4">The Quenderin Vision</h3>
                        <p className="mb-4">
                            Quenderin is the pursuit of <strong>Autonomous Computer Usage</strong>. Think of it as autonomous driving, but for your desktop and mobile OS. The vision is for Quenderin to sit quietly, watching how you work and learning from your daily interactions. Then, it takes over to do those exact tasks—only faster and better.
                        </p>
                        <p className="mb-4">
                            It is designed to be an exclusive, voice-operated assistant that sits in front of you. When you intervene to correct it, Quenderin learns from that correction instantly.
                        </p>
                        <p className="mb-4 text-purple-700 dark:text-purple-300 font-medium">
                            We must also acknowledge a core architectural irony: This entire Quenderin system has been and will be explicitly written using state-of-the-art Google models. However, the agent itself runs <strong>exclusively on offline local models</strong>, ensuring zero token costs and absolute data privacy for the end user.
                        </p>
                    </section>

                    <section>
                        <h3 className="text-lg font-medium text-zinc-900 dark:text-white mb-4 border-b border-zinc-200 dark:border-zinc-800 pb-2">How it works</h3>
                        <p className="mb-4">
                            Using ADB (Android Debug Bridge), Quenderin connects to a running emulator and dumps the current View Hierarchy (XML) into a parser. The backend filters this XML down to purely interactable nodes (buttons, lists, inputs), discarding everything else.
                        </p>
                        <p>
                            A local LLM reads these parsed coordinates and decides the next sequence of inputs (<code className="bg-zinc-100 dark:bg-[#27272a] px-1 text-sm rounded text-pink-600 dark:text-pink-400">TAP</code>, <code className="bg-zinc-100 dark:bg-[#27272a] px-1 text-sm rounded text-pink-600 dark:text-pink-400">SWIPE</code>, <code className="bg-zinc-100 dark:bg-[#27272a] px-1 text-sm rounded text-pink-600 dark:text-pink-400">TEXT</code>) fully autonomously based on your original natural language goal. Finally, the backend executes those touches via `adb shell input` and repeats the loop.
                        </p>
                    </section>

                    <section>
                        <h3 className="text-lg font-medium text-zinc-900 dark:text-white mb-4 border-b border-zinc-200 dark:border-zinc-800 pb-2">Compatible Offline Models</h3>
                        <p className="mb-6">
                            Because this system relies heavily on reading coordinates and outputting strict command sequences, your choice of offline model heavily influences performance. Here are all supported paradigms and their pros/cons for the end user:
                        </p>
                        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                            <div className="bg-zinc-50 dark:bg-[#27272a] p-5 rounded-2xl border border-zinc-200 dark:border-[#3f3f46]">
                                <div className="font-semibold text-emerald-600 dark:text-emerald-400 mb-2">Llama 3 (8B Instruct)</div>
                                <p className="text-[14px] text-zinc-600 dark:text-zinc-400 mb-3 text-sm italic">The Current Standard</p>
                                <ul className="text-[14px] pace-y-2 mb-2">
                                    <li className="mb-1"><strong className="text-zinc-800 dark:text-zinc-200">Pros:</strong> Excellent reasoning, perfectly formats output JSON/Syntax, blazing fast inference on M-series Macs or modern GPUs.</li>
                                    <li><strong className="text-zinc-800 dark:text-zinc-200">Cons:</strong> Requires ~5-6GB of system RAM to run comfortably alongside the Android emulator.</li>
                                </ul>
                            </div>

                            <div className="bg-zinc-50 dark:bg-[#27272a] p-5 rounded-2xl border border-zinc-200 dark:border-[#3f3f46]">
                                <div className="font-semibold text-blue-600 dark:text-blue-400 mb-2">Mistral (v0.3 Instruct)</div>
                                <p className="text-[14px] text-zinc-600 dark:text-zinc-400 mb-3 text-sm italic">The Speedy Alternative</p>
                                <ul className="text-[14px] space-y-2 mb-2">
                                    <li className="mb-1"><strong className="text-zinc-800 dark:text-zinc-200">Pros:</strong> Extremely low latency, highly capable at understanding UI elements and parsing XML tags rapidly.</li>
                                    <li><strong className="text-zinc-800 dark:text-zinc-200">Cons:</strong> Can occasionally hallucinate tap coordinates if the UI hierarchy arrays get too dense or nested.</li>
                                </ul>
                            </div>

                            <div className="bg-zinc-50 dark:bg-[#27272a] p-5 rounded-2xl border border-zinc-200 dark:border-[#3f3f46] md:col-span-2">
                                <div className="font-semibold text-purple-600 dark:text-purple-400 mb-2 flex items-center gap-2"><Sparkles className="w-4 h-4" /> Phi-3 / Qwen (Smaller Models)</div>
                                <p className="text-[14px] text-zinc-600 dark:text-zinc-400 mb-3 text-sm italic">The 10-20 Year Goal</p>
                                <ul className="text-[14px] space-y-2 mb-2">
                                    <li className="mb-1"><strong className="text-zinc-800 dark:text-zinc-200">Pros:</strong> Tiny footprint (1-3GB), instantaneous inference even on old or low-end hardware without a GPU. These models represent the future of fully democratic, cost-free AI on any device.</li>
                                    <li><strong className="text-zinc-800 dark:text-zinc-200">Cons:</strong> Cannot hold context as long, often requires significantly more prompt engineering, and may get stuck in loops on complex spatial screens today.</li>
                                </ul>
                            </div>
                        </div>
                    </section>

                    <section>
                        <h3 className="text-lg font-medium text-zinc-900 dark:text-white mb-4 border-b border-zinc-200 dark:border-zinc-800 pb-2">Prerequisites</h3>
                        <ul className="list-disc pl-5 space-y-2 marker:text-zinc-400 dark:marker:text-zinc-500">
                            <li>You must have an <strong>Android Emulator</strong> running natively on your system.</li>
                            <li>Ensure the emulator screen is <strong>unlocked</strong> before sending a command.</li>
                            <li>The dashboard server must be running via <code className="bg-zinc-100 dark:bg-[#27272a] px-1.5 py-0.5 rounded text-sm font-mono border border-zinc-200 dark:border-[#3f3f46]">npm run dashboard</code></li>
                        </ul>
                    </section>
                </div>

            </div>
        </div>
    );
}
