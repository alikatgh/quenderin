import { useState, useEffect } from 'react';
import { Activity, ArrowLeft, Target, Trophy, AlertTriangle } from 'lucide-react';

interface MetricRecord {
    id: string;
    goal_text: string;
    success: boolean;
    total_steps: number;
    duration_ms: number;
    total_retries: number;
    timestamp: string;
}

export function Metrics({ onBack }: { onBack: () => void }) {
    const [metrics, setMetrics] = useState<MetricRecord[]>([]);
    const [isLoading, setIsLoading] = useState(true);

    useEffect(() => {
        fetch('/api/metrics')
            .then(res => res.json())
            .then(data => {
                // Ensure data is an array
                if (Array.isArray(data)) {
                    setMetrics(data.reverse()); // Show newest first
                }
            })
            .catch(err => console.error("Failed to load metrics", err))
            .finally(() => setIsLoading(false));
    }, []);

    const totalRuns = metrics.length;
    const successRuns = metrics.filter((m: MetricRecord) => m.success).length;
    const successRate = totalRuns ? Math.round((successRuns / totalRuns) * 100) : 0;

    // Calculate average retries for successful runs
    const avgRetries = successRuns ? (metrics.filter((m: MetricRecord) => m.success).reduce((acc: number, m: MetricRecord) => acc + m.total_retries, 0) / successRuns).toFixed(1) : 0;

    return (
        <div className="flex flex-col h-full bg-white dark:bg-[#18181b] overflow-y-auto">
            <div className="max-w-4xl mx-auto w-full p-8">
                <button
                    onClick={onBack}
                    className="flex items-center gap-2 text-sm text-zinc-500 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 mb-8 transition-colors"
                >
                    <ArrowLeft className="w-4 h-4" />
                    Back to Setup
                </button>

                <div className="flex items-center gap-3 mb-8">
                    <Activity className="w-8 h-8 text-blue-500" />
                    <div>
                        <h1 className="text-2xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-100">Agent Telemetry</h1>
                        <p className="text-zinc-500 dark:text-zinc-400 mt-1">Review the OS loop performance, success rates, and verifier interventions.</p>
                    </div>
                </div>

                {/* Dashboard Cards */}
                <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-8">
                    <div className="bg-zinc-50 border border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl p-5 shadow-sm">
                        <div className="flex items-center gap-2 text-zinc-500 dark:text-zinc-400 mb-2">
                            <Target className="w-4 h-4" />
                            <h3 className="text-sm font-medium">Total Execution Runs</h3>
                        </div>
                        <p className="text-3xl font-bold text-zinc-900 dark:text-white">{totalRuns}</p>
                    </div>

                    <div className="bg-zinc-50 border border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl p-5 shadow-sm">
                        <div className="flex items-center gap-2 text-zinc-500 dark:text-zinc-400 mb-2">
                            <Trophy className="w-4 h-4" />
                            <h3 className="text-sm font-medium">Global Success Rate</h3>
                        </div>
                        <div className="flex items-end gap-2">
                            <p className="text-3xl font-bold text-zinc-900 dark:text-white">{successRate}%</p>
                            <span className="text-sm text-zinc-500 mb-1">({successRuns} / {totalRuns})</span>
                        </div>
                    </div>

                    <div className="bg-zinc-50 border border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl p-5 shadow-sm">
                        <div className="flex items-center gap-2 text-zinc-500 dark:text-zinc-400 mb-2">
                            <AlertTriangle className="w-4 h-4" />
                            <h3 className="text-sm font-medium">Avg Verifier Saves</h3>
                        </div>
                        <div className="flex items-end gap-2">
                            <p className="text-3xl font-bold text-zinc-900 dark:text-white">{avgRetries}</p>
                            <span className="text-sm text-zinc-500 mb-1">retries/success</span>
                        </div>
                    </div>
                </div>

                {/* Run History Table */}
                <h3 className="text-lg font-medium text-zinc-900 dark:text-zinc-100 mb-4">Detailed Execution History</h3>

                {isLoading ? (
                    <div className="text-zinc-500">Loading telemetry...</div>
                ) : metrics.length === 0 ? (
                    <div className="text-center py-12 bg-zinc-50 border border-zinc-200 dark:bg-zinc-900/50 dark:border-zinc-800 rounded-xl">
                        <Activity className="w-8 h-8 mx-auto text-zinc-400 mb-3" />
                        <p className="text-zinc-600 dark:text-zinc-400">No telemetry recorded yet.</p>
                        <p className="text-sm text-zinc-500 mt-1">Run an agent goal to see it appear here.</p>
                    </div>
                ) : (
                    <div className="border border-zinc-200 dark:border-zinc-800 rounded-xl overflow-hidden shadow-sm">
                        <table className="min-w-[800px] w-full text-left text-sm text-zinc-600 dark:text-zinc-300">
                            <thead className="bg-zinc-50 dark:bg-zinc-900/80 border-b border-zinc-200 dark:border-zinc-800 text-zinc-900 dark:text-zinc-100">
                                <tr>
                                    <th className="px-4 py-3 font-medium">Goal</th>
                                    <th className="px-4 py-3 font-medium w-24">Status</th>
                                    <th className="px-4 py-3 font-medium w-24">Steps</th>
                                    <th className="px-4 py-3 font-medium w-28">Duration</th>
                                    <th className="px-4 py-3 font-medium w-32">Verifier Retries</th>
                                </tr>
                            </thead>
                            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                                {metrics.map((m: MetricRecord) => (
                                    <tr key={m.id} className="bg-white dark:bg-[#18181b] hover:bg-zinc-50 dark:hover:bg-zinc-900/50 transition-colors">
                                        <td className="px-4 py-3 font-medium text-zinc-900 dark:text-zinc-200">{m.goal_text}</td>
                                        <td className="px-4 py-3">
                                            {m.success ? (
                                                <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-emerald-100 text-emerald-800 dark:bg-emerald-500/20 dark:text-emerald-400">
                                                    Success
                                                </span>
                                            ) : (
                                                <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-800 dark:bg-red-500/20 dark:text-red-400">
                                                    Failed
                                                </span>
                                            )}
                                        </td>
                                        <td className="px-4 py-3">{m.total_steps}</td>
                                        <td className="px-4 py-3">{(m.duration_ms / 1000).toFixed(1)}s</td>
                                        <td className="px-4 py-3">
                                            {m.total_retries > 0 ? (
                                                <span className="text-orange-600 dark:text-orange-400 font-medium">{m.total_retries} warnings</span>
                                            ) : (
                                                <span className="text-zinc-400">0</span>
                                            )}
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
