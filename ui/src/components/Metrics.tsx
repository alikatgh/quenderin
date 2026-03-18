import { useState, useEffect } from 'react';
import { Activity, ArrowLeft, Target, Trophy, Clock, Zap, Download } from 'lucide-react';

interface MetricRecord {
    id: string;
    goal_text: string;
    success: boolean;
    total_steps: number;
    duration_ms: number;
    total_retries: number;
    timestamp: string;
}

/** Inline SVG bar chart — no external dependency */
function MiniBarChart({ values, colors, labels, height = 80 }: {
    values: number[];
    colors: string[];
    labels?: string[];
    height?: number;
}) {
    if (values.length === 0) return null;
    const max = Math.max(...values, 1);
    const barW = Math.max(6, Math.floor(280 / values.length) - 2);
    const totalW = values.length * (barW + 2);

    return (
        <svg width={totalW} height={height} className="overflow-visible">
            {values.map((v, i) => {
                const barH = Math.max(2, Math.round((v / max) * (height - 16)));
                const x = i * (barW + 2);
                const y = height - barH - 14;
                return (
                    <g key={i}>
                        <rect
                            x={x} y={y}
                            width={barW} height={barH}
                            rx={2}
                            fill={colors[i] ?? colors[0]}
                            opacity={0.85}
                        />
                        {labels && (
                            <text
                                x={x + barW / 2} y={height - 2}
                                textAnchor="middle"
                                fontSize={9}
                                fill="currentColor"
                                className="text-zinc-400 dark:text-zinc-500"
                            >
                                {labels[i]}
                            </text>
                        )}
                    </g>
                );
            })}
        </svg>
    );
}

/** Inline SVG line chart */
function MiniLineChart({ values, color = '#6366f1', height = 60 }: {
    values: number[];
    color?: string;
    height?: number;
}) {
    if (values.length < 2) return null;
    const max = Math.max(...values, 1);
    const w = 280;
    const stepX = w / (values.length - 1);
    const points = values.map((v, i) => {
        const x = i * stepX;
        const y = height - Math.max(2, Math.round((v / max) * (height - 4)));
        return `${x},${y}`;
    }).join(' ');

    return (
        <svg width={w} height={height} className="overflow-visible">
            <polyline
                points={points}
                fill="none"
                stroke={color}
                strokeWidth={2}
                strokeLinejoin="round"
                strokeLinecap="round"
            />
            {values.map((v, i) => (
                <circle
                    key={i}
                    cx={i * stepX}
                    cy={height - Math.max(2, Math.round((v / max) * (height - 4)))}
                    r={3}
                    fill={color}
                />
            ))}
        </svg>
    );
}

function exportMetricsCsv(metrics: MetricRecord[]) {
    const header = 'timestamp,goal,success,steps,duration_s,retries\n';
    const rows = metrics.map(m =>
        `"${m.timestamp}","${m.goal_text.replace(/"/g, '""')}",${m.success},${m.total_steps},${(m.duration_ms / 1000).toFixed(2)},${m.total_retries}`
    ).join('\n');
    const blob = new Blob([header + rows], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `quenderin-metrics-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
}

export function Metrics({ onBack }: { onBack: () => void }) {
    const [metrics, setMetrics] = useState<MetricRecord[]>([]);
    const [isLoading, setIsLoading] = useState(true);

    useEffect(() => {
        fetch('/api/metrics')
            .then(res => res.json())
            .then(data => {
                if (Array.isArray(data)) {
                    setMetrics(data.reverse());
                }
            })
            .catch(err => console.error('Failed to load metrics', err))
            .finally(() => setIsLoading(false));
    }, []);

    const totalRuns = metrics.length;
    const successRuns = metrics.filter(m => m.success).length;
    const successRate = totalRuns ? Math.round((successRuns / totalRuns) * 100) : 0;
    const avgRetries = successRuns
        ? (metrics.filter(m => m.success).reduce((a, m) => a + m.total_retries, 0) / successRuns).toFixed(1)
        : 0;
    const avgDurationSec = totalRuns
        ? (metrics.reduce((a, m) => a + m.duration_ms, 0) / totalRuns / 1000).toFixed(1)
        : 0;
    const avgSteps = totalRuns
        ? (metrics.reduce((a, m) => a + m.total_steps, 0) / totalRuns).toFixed(1)
        : 0;

    // Chart data — last 20 runs
    const recent = metrics.slice(0, 20).reverse();
    const successBarColors = recent.map(m => m.success ? '#10b981' : '#ef4444');
    const successBarValues = recent.map(() => 1);
    const durationValues = recent.map(m => m.duration_ms / 1000);
    const stepsValues = recent.map(m => m.total_steps);

    return (
        <div className="flex flex-col h-full bg-white dark:bg-[#18181b] overflow-y-auto">
            <div className="max-w-5xl mx-auto w-full p-8">

                {/* Header */}
                <div className="flex items-center justify-between mb-8">
                    <button
                        onClick={onBack}
                        className="flex items-center gap-2 text-sm text-zinc-500 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 transition-colors"
                    >
                        <ArrowLeft className="w-4 h-4" />
                        Back
                    </button>
                    {metrics.length > 0 && (
                        <button
                            onClick={() => exportMetricsCsv(metrics)}
                            className="flex items-center gap-2 px-3 py-1.5 text-xs font-semibold border border-zinc-200 dark:border-zinc-700 rounded-lg hover:bg-zinc-50 dark:hover:bg-zinc-800 text-zinc-600 dark:text-zinc-400 transition-colors"
                        >
                            <Download className="w-3.5 h-3.5" /> Export CSV
                        </button>
                    )}
                </div>

                <div className="flex items-center gap-3 mb-8">
                    <Activity className="w-8 h-8 text-blue-500" />
                    <div>
                        <h1 className="text-2xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-100">Agent Telemetry</h1>
                        <p className="text-zinc-500 dark:text-zinc-400 mt-1">Real-time performance analytics for your local AI agent.</p>
                    </div>
                </div>

                {/* KPI Cards */}
                <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
                    {[
                        { icon: Target, label: 'Total Runs', value: String(totalRuns), color: 'blue' },
                        { icon: Trophy, label: 'Success Rate', value: `${successRate}%`, sub: `${successRuns}/${totalRuns}`, color: successRate >= 70 ? 'emerald' : successRate >= 40 ? 'amber' : 'red' },
                        { icon: Clock, label: 'Avg Duration', value: `${avgDurationSec}s`, color: 'purple' },
                        { icon: Zap, label: 'Avg Steps', value: String(avgSteps), sub: `${avgRetries} retries/run`, color: 'orange' },
                    ].map(({ icon: Icon, label, value, sub }) => (
                        <div key={label} className="bg-zinc-50 border border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl p-5 shadow-sm">
                            <div className="flex items-center gap-2 text-zinc-500 dark:text-zinc-400 mb-3">
                                <Icon className="w-4 h-4" />
                                <span className="text-xs font-semibold uppercase tracking-wide">{label}</span>
                            </div>
                            <p className={`text-3xl font-bold text-zinc-900 dark:text-white`}>{value}</p>
                            {sub && <p className="text-xs text-zinc-500 dark:text-zinc-400 mt-1">{sub}</p>}
                        </div>
                    ))}
                </div>

                {/* Charts Row */}
                {recent.length > 1 && (
                    <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-8">
                        <div className="bg-zinc-50 border border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl p-5 shadow-sm">
                            <h3 className="text-xs font-bold uppercase tracking-widest text-zinc-400 dark:text-zinc-500 mb-3">Success / Fail (last {recent.length})</h3>
                            <div className="overflow-x-auto">
                                <MiniBarChart values={successBarValues} colors={successBarColors} height={70} />
                            </div>
                            <div className="flex items-center gap-4 mt-3 text-[11px]">
                                <span className="flex items-center gap-1.5"><span className="w-2.5 h-2.5 rounded-sm bg-emerald-500 inline-block" />Success</span>
                                <span className="flex items-center gap-1.5"><span className="w-2.5 h-2.5 rounded-sm bg-red-500 inline-block" />Failed</span>
                            </div>
                        </div>

                        <div className="bg-zinc-50 border border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl p-5 shadow-sm">
                            <h3 className="text-xs font-bold uppercase tracking-widest text-zinc-400 dark:text-zinc-500 mb-3">Duration (seconds)</h3>
                            <div className="overflow-x-auto">
                                <MiniLineChart values={durationValues} color="#6366f1" height={70} />
                            </div>
                            <p className="text-[11px] text-zinc-400 dark:text-zinc-500 mt-3">Each point = one task run</p>
                        </div>

                        <div className="bg-zinc-50 border border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl p-5 shadow-sm">
                            <h3 className="text-xs font-bold uppercase tracking-widest text-zinc-400 dark:text-zinc-500 mb-3">Steps per Task</h3>
                            <div className="overflow-x-auto">
                                <MiniLineChart values={stepsValues} color="#f59e0b" height={70} />
                            </div>
                            <p className="text-[11px] text-zinc-400 dark:text-zinc-500 mt-3">Fewer steps = more efficient</p>
                        </div>
                    </div>
                )}

                {/* Run History Table */}
                <div className="flex items-center justify-between mb-4">
                    <h3 className="text-lg font-semibold text-zinc-900 dark:text-zinc-100">Execution History</h3>
                    {totalRuns > 0 && (
                        <span className="text-xs text-zinc-500 dark:text-zinc-400">{totalRuns} total runs</span>
                    )}
                </div>

                {isLoading ? (
                    <div className="text-zinc-500 text-sm">Loading telemetry...</div>
                ) : metrics.length === 0 ? (
                    <div className="text-center py-16 bg-zinc-50 border border-zinc-200 dark:bg-zinc-900/50 dark:border-zinc-800 rounded-xl">
                        <Activity className="w-8 h-8 mx-auto text-zinc-400 mb-3" />
                        <p className="text-zinc-600 dark:text-zinc-400 font-medium">No telemetry recorded yet</p>
                        <p className="text-sm text-zinc-500 mt-1">Run an agent goal to see analytics appear here.</p>
                    </div>
                ) : (
                    <div className="border border-zinc-200 dark:border-zinc-800 rounded-xl overflow-hidden shadow-sm overflow-x-auto">
                        <table className="min-w-[700px] w-full text-left text-sm text-zinc-600 dark:text-zinc-300">
                            <thead className="bg-zinc-50 dark:bg-zinc-900/80 border-b border-zinc-200 dark:border-zinc-800 text-zinc-900 dark:text-zinc-100">
                                <tr>
                                    <th className="px-4 py-3 font-semibold">Goal</th>
                                    <th className="px-4 py-3 font-semibold w-24">Status</th>
                                    <th className="px-4 py-3 font-semibold w-20">Steps</th>
                                    <th className="px-4 py-3 font-semibold w-24">Duration</th>
                                    <th className="px-4 py-3 font-semibold w-20">Retries</th>
                                    <th className="px-4 py-3 font-semibold w-36 hidden md:table-cell">Time</th>
                                </tr>
                            </thead>
                            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                                {metrics.map(m => (
                                    <tr key={m.id} className="bg-white dark:bg-[#18181b] hover:bg-zinc-50 dark:hover:bg-zinc-900/50 transition-colors">
                                        <td className="px-4 py-3 font-medium text-zinc-900 dark:text-zinc-200 max-w-xs truncate" title={m.goal_text}>{m.goal_text}</td>
                                        <td className="px-4 py-3">
                                            {m.success ? (
                                                <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-semibold bg-emerald-100 text-emerald-800 dark:bg-emerald-500/20 dark:text-emerald-400">
                                                    Success
                                                </span>
                                            ) : (
                                                <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-semibold bg-red-100 text-red-800 dark:bg-red-500/20 dark:text-red-400">
                                                    Failed
                                                </span>
                                            )}
                                        </td>
                                        <td className="px-4 py-3 tabular-nums">{m.total_steps}</td>
                                        <td className="px-4 py-3 tabular-nums">{(m.duration_ms / 1000).toFixed(1)}s</td>
                                        <td className="px-4 py-3">
                                            {m.total_retries > 0 ? (
                                                <span className="text-orange-600 dark:text-orange-400 font-semibold tabular-nums">{m.total_retries}</span>
                                            ) : (
                                                <span className="text-zinc-400">—</span>
                                            )}
                                        </td>
                                        <td className="px-4 py-3 text-xs text-zinc-400 dark:text-zinc-500 hidden md:table-cell">
                                            {new Date(m.timestamp).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })}
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                )}
            </div>
        </div>
    );
}
