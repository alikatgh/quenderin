import { useEffect, useRef, useState } from 'react';
import { apiFetch } from '../../lib/api.js';

interface Proposal { id: string; text: string; saved: boolean }
interface Status { installed: boolean; availableMemoryBytes: number; totalMemoryBytes?: number; requiredMemoryBytes: number; downloadBytes: number; unavailableReason: string | null; storageUnavailableReason?: string | null; busy: boolean; progress: number; batchId?: string; proposals: Proposal[] }
const draft = { conversation: '' }; // RAM only; retain the explicitly selected input across Settings navigation.
const focus = 'focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-purple-500';
const button = `rounded-lg border border-zinc-300 dark:border-zinc-700 px-3 py-2 text-[13px] font-medium disabled:opacity-50 disabled:cursor-not-allowed ${focus}`;

export function HyMemorySection() {
    const [conversation, setConversation] = useState(draft.conversation);
    const [status, setStatus] = useState<Status | null>(null);
    const [selected, setSelected] = useState<Set<string>>(new Set());
    const [busy, setBusy] = useState(false);
    const [message, setMessage] = useState('Choose a conversation to review. Nothing is saved automatically.');
    const [error, setError] = useState<string | null>(null);
    const mounted = useRef(false), active = useRef(false), abort = useRef<AbortController | null>(null);
    async function request(path: string, body?: object, signal?: AbortSignal) {
        const response = await apiFetch(`/api/memory/hy/${path}`, { ...(body ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) } : {}), signal });
        const value = await response.json(); if (!response.ok) throw new Error(String(value.error ?? 'Hy-Memory operation failed.').slice(0, 2048)); return value;
    }
    async function refresh() {
        try { const value = await request('status') as Status; if (mounted.current) setStatus(value); }
        catch (cause) { if (mounted.current) setError(cause instanceof Error ? cause.message : 'The specialist workflow is unavailable in this build.'); }
    }
    useEffect(() => {
        mounted.current = true; void refresh();
        return () => { mounted.current = false; abort.current?.abort(); if (active.current) void request('cancel', {}).catch(() => {}); };
    }, []);
    useEffect(() => { if (!busy) return; const timer = setInterval(() => { void refresh(); }, 1000); return () => clearInterval(timer); }, [busy]);
    async function run(kind: 'install' | 'propose' | 'approve') {
        if (active.current) return;
        active.current = true; setBusy(true); setError(null); abort.current = new AbortController();
        setMessage(kind === 'install' ? 'Installing and verifying the complete pinned specialist…' : kind === 'propose' ? 'Verifying the specialist and extracting proposals…' : 'Saving only the selected proposals…');
        try {
            await request(kind, kind === 'propose' ? { conversation } : kind === 'approve' ? { batchId: status?.batchId, proposalIds: [...selected] } : {}, abort.current.signal);
            if (mounted.current) { setSelected(new Set()); setMessage(kind === 'approve' ? 'Selected proposals saved. Other proposals remain unsaved.' : kind === 'propose' ? 'Review each proposal. All proposals start unchecked.' : 'Pinned specialist installed. It remains separate from the answer model.'); }
        } catch (cause) { if (mounted.current) { setMessage('Your conversation and existing memories are kept.'); setError(cause instanceof Error ? cause.message.slice(0, 2048) : 'Hy-Memory operation failed.'); } }
        finally { active.current = false; abort.current = null; if (mounted.current) { setBusy(false); await refresh(); } }
    }
    const bytes = new TextEncoder().encode(conversation).byteLength;
    const blocked = status?.unavailableReason ?? (status?.totalMemoryBytes !== undefined && status.totalMemoryBytes < status.requiredMemoryBytes ? 'Requires a device with at least 32 GiB of memory.' : null);
    return <section className="premium-card p-6 space-y-4" aria-labelledby="hy-memory-title">
        <div><h2 id="hy-memory-title" className="text-[15px] font-semibold">Hy-Memory proposals</h2><p className="mt-1 text-[12px] leading-5 text-zinc-500 dark:text-zinc-400">A separate local memory writer. Paste only the conversation you want reviewed; approve individual facts before they enter private app storage.</p></div>
        <p className="text-[12px] leading-5 text-zinc-500 dark:text-zinc-400">Experimental community conversion · Apache-2.0 · 18,236,702,240 bytes · 32 GiB available-memory floor. Model inference has not been validated. Expert width 768 follows pinned conversion metadata; files are never patched.</p>
        {blocked && <p className="text-[12px] text-amber-700 dark:text-amber-400">{blocked}</p>}
        {status && !blocked && status.availableMemoryBytes < status.requiredMemoryBytes && <p className="text-[12px] text-zinc-500 dark:text-zinc-400">The idle answer model is released before proposals run. Available memory is checked again before loading the specialist.</p>}
        {status?.storageUnavailableReason && <p className="text-[12px] text-amber-700 dark:text-amber-400">{status.storageUnavailableReason}</p>}
        <button type="button" onClick={() => void run('install')} disabled={!status || busy || !!blocked} className={button}>{status?.installed ? 'Verify installed specialist' : 'Install Hy-Memory specialist (18.24 GB)'}</button>
        {busy && status && status.progress > 0 && status.progress < 1 && <progress aria-label="Hy-Memory installation progress" max={1} value={status.progress} className="block w-full accent-purple-600" />}
        <div><label htmlFor="hy-memory-conversation" className="block text-[13px] font-medium mb-2">Selected conversation</label><textarea id="hy-memory-conversation" rows={5} maxLength={8192} disabled={busy} value={conversation} onChange={event => { draft.conversation = event.target.value; setConversation(event.target.value); }} aria-describedby="hy-memory-limit" className={`w-full rounded-lg border border-zinc-300 dark:border-zinc-700 bg-transparent p-3 text-[13px] ${focus}`} /><p id="hy-memory-limit" className="text-[11px] text-zinc-500">{bytes.toLocaleString()} / 8,192 UTF-8 bytes. No automatic conversation collection.</p></div>
        <div className="flex flex-wrap gap-2"><button type="button" onClick={() => void run('propose')} disabled={!status?.installed || busy || !!blocked || !conversation.trim() || bytes > 8192} className={button}>Preview memory proposals</button>{busy && <button type="button" onClick={() => { abort.current?.abort(); void request('cancel', {}).catch(() => {}); }} className={button}>Cancel</button>}</div>
        {status?.proposals.map(proposal => <label key={proposal.id} className="flex gap-3 items-start text-[13px] leading-6"><input type="checkbox" checked={selected.has(proposal.id)} disabled={busy || proposal.saved} onChange={event => { const next = new Set(selected); if (event.target.checked) next.add(proposal.id); else next.delete(proposal.id); setSelected(next); }} className="mt-1.5 accent-purple-600" /><span className="break-words">{proposal.text}{proposal.saved && <span className="ml-2 text-[11px] text-emerald-700 dark:text-emerald-400">Saved</span>}</span></label>)}
        {!!status?.proposals.length && <button type="button" onClick={() => void run('approve')} disabled={busy || selected.size === 0 || !!status.storageUnavailableReason} className={button}>Save {selected.size} selected {selected.size === 1 ? 'memory' : 'memories'} privately</button>}
        <p role="status" aria-live="polite" className="text-[12px] text-zinc-500 dark:text-zinc-400">{message}</p>{error && <div role="alert" className="text-[12px] text-red-700 dark:text-red-400"><p>{error}</p><button type="button" onClick={() => void refresh()} className={`mt-1 underline ${focus}`}>Retry status</button></div>}
    </section>;
}
