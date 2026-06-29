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
        const x = parseInt(parts[1], 10);
        const y = parseInt(parts[2], 10);
        // Guard NaN: a malformed TAP command would otherwise position the crosshair at (NaN, NaN),
        // silently breaking the indicator (deep-hunt).
        if (!Number.isNaN(x) && !Number.isNaN(y)) targetTap = { x, y };
    }

    return (
        <div
            className={`flex-shrink-0 bg-white dark:bg-[#18181b] border-l border-zinc-200 dark:border-zinc-800 transition-all duration-300 ease-in-out flex flex-col fixed inset-y-0 right-0 md:sticky md:top-0 md:self-stretch md:inset-auto z-40 shadow-[-8px_0_24px_rgba(0,0,0,0.06)] dark:shadow-none ${isOpen ? 'w-full sm:w-[380px] xl:w-[420px] translate-x-0' : 'w-0 translate-x-full overflow-hidden'}`}
        >
            <div className="h-full py-5 px-5 flex flex-col items-center w-full sm:w-[380px] xl:w-[420px] overflow-y-auto overflow-x-hidden">

                <div className="w-full flex items-center justify-between mb-5">
                    <h3 className="text-[11px] font-semibold text-zinc-400 dark:text-zinc-500 uppercase tracking-wider flex items-center gap-1.5">
                        <Smartphone className="w-3.5 h-3.5" /> Device
                    </h3>
                    {currentUI.length > 0 && <span className="text-[10px] font-semibold text-blue-500 dark:text-blue-400 tabular-nums">{currentUI.length} nodes</span>}
                </div>

                <div className="w-[300px] xl:w-[330px] h-[650px] xl:h-[700px] scale-[0.85] sm:scale-100 origin-top bg-zinc-900 dark:bg-black border-[5px] border-zinc-200 dark:border-zinc-800 rounded-[36px] relative overflow-hidden shadow-xl flex-shrink-0 ring-1 ring-black/5 dark:ring-white/5 transition-all">

                    <div className="absolute top-0 w-full h-7 bg-zinc-900 dark:bg-black z-30 flex justify-center">
                        <div className="w-[90px] h-[20px] bg-zinc-200 dark:bg-zinc-800 rounded-b-xl shadow-inner"></div>
                    </div>

                    <div className="absolute inset-0 bg-[#0e0e11] mt-6 mb-2 overflow-hidden relative">
                        <div className="absolute inset-0 bg-[linear-gradient(rgba(255,255,255,0.05)_1px,transparent_1px),linear-gradient(90deg,rgba(255,255,255,0.05)_1px,transparent_1px)] bg-[size:24px_24px]"></div>

                        {screenshotBase64 && (
                            <img
                                src={`data:image/png;base64,${screenshotBase64}`}
                                alt="Live Device Screen"
                                className="absolute inset-0 w-full h-full object-contain z-0 pointer-events-none opacity-80"
                            />
                        )}

                        {currentUI.length === 0 ? (
                            <div role="status" aria-live="polite" className="absolute inset-0 flex flex-col items-center justify-center text-zinc-500 animate-entrance">
                                <TerminalSquare className="w-8 h-8 mb-4 opacity-20 text-blue-500" />
                                <span className="text-[10px] uppercase tracking-wider font-semibold text-zinc-500/50">Waiting for sync</span>
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
                                        <div className="absolute hidden group-hover:block bottom-[calc(100%+6px)] left-1/2 -translate-x-1/2 bg-zinc-900 border border-white/10 px-2.5 py-1.5 rounded-lg text-[10px] whitespace-nowrap z-[100] shadow-lg font-mono text-zinc-300 pointer-events-none">
                                            <span className="text-zinc-500 text-[9px]">{node.className.split('.').pop()}</span><br />
                                            {node.text && <><span className="text-blue-400">{`"${node.text}"`}</span><br /></>}
                                            {node.contentDesc && <span className="text-purple-400">{`desc:"${node.contentDesc}"`}</span>}
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
                        <div className="w-24 h-1 bg-zinc-600 dark:bg-zinc-700 rounded-full"></div>
                    </div>
                </div>

            </div>
        </div>
    );
}
