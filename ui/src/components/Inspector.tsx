import { TerminalSquare, Smartphone } from 'lucide-react';
import { UIElement, LogEntry } from '../types/index.js';

interface InspectorProps {
    isOpen: boolean;
    currentUI: UIElement[];
    logs: LogEntry[];
    screenshotBase64?: string;
}

export function Inspector({ isOpen, currentUI, logs, screenshotBase64 }: InspectorProps) {
    let targetTap: { x: number, y: number } | null = null;
    const lastDecide = [...logs].reverse().find(l => l.type === 'decide');
    if (lastDecide && lastDecide.command?.startsWith('TAP')) {
        const parts = lastDecide.command.split(' ');
        targetTap = { x: parseInt(parts[1], 10), y: parseInt(parts[2], 10) }
    }

    return (
        <div
            className={`flex-shrink-0 bg-white dark:bg-[#18181b] border-l border-zinc-200 dark:border-[#27272a] transition-all duration-300 ease-in-out flex flex-col fixed inset-y-0 right-0 md:sticky md:top-0 md:self-stretch md:inset-auto z-40 shadow-[-20px_0_40px_rgba(0,0,0,0.1)] dark:shadow-none ${isOpen ? 'w-full sm:w-[380px] xl:w-[420px] translate-x-0' : 'w-0 translate-x-full overflow-hidden'}`}
        >
            <div className="h-full py-6 px-6 flex flex-col items-center w-full sm:w-[380px] xl:w-[420px] overflow-y-auto overflow-x-hidden">

                <div className="w-full flex items-center justify-between mb-8">
                    <h3 className="text-[11px] font-bold text-zinc-400 dark:text-zinc-500 uppercase tracking-widest flex items-center gap-2">
                        <Smartphone className="w-3.5 h-3.5" /> Live Device View
                    </h3>
                    {currentUI.length > 0 && <span className="bg-blue-100 dark:bg-blue-500/10 text-blue-600 dark:text-blue-400 border border-blue-200 dark:border-blue-500/20 px-2 py-0.5 rounded-lg text-[10px] font-bold tracking-wide shadow-sm">{currentUI.length} Nodes</span>}
                </div>

                <div className="w-[300px] xl:w-[330px] h-[650px] xl:h-[700px] scale-[0.85] sm:scale-100 origin-top bg-zinc-900 dark:bg-black border-[6px] border-zinc-200 dark:border-[#27272a] rounded-[36px] relative overflow-hidden shadow-2xl flex-shrink-0 ring-1 ring-black/5 dark:ring-white/5 transition-all duration-500">

                    <div className="absolute top-0 w-full h-8 bg-zinc-900 dark:bg-black z-30 flex justify-center">
                        <div className="w-[100px] h-[22px] bg-zinc-200 dark:bg-[#18181b] rounded-b-2xl border border-transparent shadow-inner"></div>
                    </div>

                    <div className="absolute inset-0 bg-[#0e0e11] mt-7 mb-2 overflow-hidden relative">
                        <div className="absolute inset-0 bg-[linear-gradient(rgba(255,255,255,0.05)_1px,transparent_1px),linear-gradient(90deg,rgba(255,255,255,0.05)_1px,transparent_1px)] bg-[size:24px_24px]"></div>

                        {screenshotBase64 && (
                            <img
                                src={`data:image/png;base64,${screenshotBase64}`}
                                alt="Live Device Screen"
                                className="absolute inset-0 w-full h-full object-contain z-0 pointer-events-none opacity-80"
                            />
                        )}

                        {currentUI.length === 0 ? (
                            <div className="absolute inset-0 flex flex-col items-center justify-center text-zinc-500 animate-entrance">
                                <TerminalSquare className="w-8 h-8 mb-4 opacity-20 text-blue-500" />
                                <span className="text-[10px] uppercase tracking-[0.2em] font-bold text-zinc-500/50">Waiting for Sync</span>
                            </div>
                        ) : (
                            currentUI.map(node => {
                                const left = (node.rect.x / 1080) * 100;
                                const top = (node.rect.y / 2400) * 100;
                                const width = (node.rect.width / 1080) * 100;
                                const height = (node.rect.height / 2400) * 100;

                                return (
                                    <div
                                        key={node.id}
                                        className={`absolute border transition-all duration-300 group
                          ${node.clickable
                                                ? 'border-emerald-500/30 bg-emerald-500/5 hover:border-emerald-400/90 hover:bg-emerald-400/20 z-20 cursor-crosshair hover:shadow-[0_0_10px_rgba(16,185,129,0.2)]'
                                                : 'border-zinc-800 hover:border-zinc-500 hover:bg-zinc-500/10 z-10'}`}
                                        style={{ left: `${left}%`, top: `${top}%`, width: `${width}%`, height: `${height}%` }}
                                    >
                                        <div className="absolute hidden group-hover:block bottom-[calc(100%+8px)] left-1/2 -translate-x-1/2 bg-zinc-900 dark:bg-zinc-900 border border-white/10 px-3 py-2 rounded-xl text-[10px] whitespace-nowrap z-[100] shadow-[0_10px_25px_-5px_rgba(0,0,0,0.5)] font-mono text-zinc-300 pointer-events-none animate-entrance backdrop-blur-md">
                                            <span className="opacity-50 text-[9px] font-bold uppercase tracking-wider">{node.className.split('.').pop()}</span><br />
                                            {node.text && <><span className="text-blue-400 font-bold">{`"${node.text}"`}</span><br /></>}
                                            {node.contentDesc && <span className="text-purple-400 font-medium">{`desc:"${node.contentDesc}"`}</span>}
                                        </div>
                                    </div>
                                )
                            })
                        )}

                        {targetTap && (
                            <div
                                className="absolute w-8 h-8 rounded-full border-[1.5px] border-orange-400/80 bg-orange-500/20 z-[80] pointer-events-none shadow-[0_0_20px_rgba(249,115,22,0.4)] transition-all duration-500"
                                style={{
                                    left: `${(targetTap.x / 1080) * 100}%`,
                                    top: `${(targetTap.y / 2400) * 100}%`,
                                    transform: 'translate(-50%, -50%)'
                                }}
                            >
                                <div className="w-full h-full rounded-full animate-ping border border-orange-400"></div>
                            </div>
                        )}
                    </div>

                    <div className="absolute bottom-1.5 w-full h-4 z-30 flex justify-center pb-1 pointer-events-none">
                        <div className="w-[100px] h-1.5 bg-zinc-700 dark:bg-[#3f3f46] rounded-full"></div>
                    </div>
                </div>

            </div>
        </div>
    );
}
