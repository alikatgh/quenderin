import { useEffect, useRef, useState } from 'react';
import type { VisionSelection, VisionWorkflowAPI } from '../../../../src/electron/visionWorkflowTypes.js';

const session: { model: VisionSelection | null; draft: string; messages: { role: 'user' | 'assistant'; content: string }[] } = { model: null, draft: '', messages: [] };
export function GraniteSection({ api = (window as Window & { quenderinVision?: VisionWorkflowAPI }).quenderinVision }: { api?: VisionWorkflowAPI }) {
    const [model, setModel] = useState<VisionSelection | null>(session.model), [draft, setDraft] = useState(session.draft);
    const [messages, setMessages] = useState(session.messages);
    const [busy, setBusy] = useState(false), [error, setError] = useState<string | null>(null);
    const [status, setStatus] = useState('Choose a complete converted model with its provenance record.');
    const active = useRef(false), cancelled = useRef(false), mounted = useRef(true);
    useEffect(() => { session.model = model; session.draft = draft; session.messages = messages; }, [model, draft, messages]);
    useEffect(() => { mounted.current = true; return () => { mounted.current = false; if (active.current) void api?.cancel().catch(() => {}); }; }, [api]);
    async function run(work: () => Promise<void>) {
        if (!api || active.current) return; active.current = true; cancelled.current = false; setBusy(true); setError(null);
        try { await work(); }
        catch (cause) { if (mounted.current && !cancelled.current) { setError(cause instanceof Error ? cause.message : 'Granite operation failed.'); setStatus('Ready to retry. Your draft is kept.'); } }
        finally { active.current = false; if (mounted.current) { setBusy(false); if (cancelled.current) setStatus('Granite operation cancelled. Your draft is kept.'); } }
    }
    return <section aria-labelledby="granite-heading" className="space-y-4 rounded-xl border border-zinc-200 p-5 dark:border-zinc-800">
        <div><h2 id="granite-heading" className="font-semibold">Granite Switch 4.1 8B</h2>
            <p className="mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-400">General text chat with a locally converted official checkpoint. At least 32 GiB of available memory is required. The decision, guardian and speech workflows are separate from this chat.</p></div>
        <details className="text-sm text-zinc-600 dark:text-zinc-400"><summary className="cursor-pointer">Prepare the model</summary>
            <p className="mt-2 leading-6">The publisher has not supplied a verified GGUF for this release. Use <code>scripts/convert_granite41.py</code> with your complete pinned official source directory and prepared Prism source. It validates all four weight shards and metadata, converts offline, and creates a new GGUF with an adjacent <code>.quenderin.json</code> provenance record. Keep both files together. The older 3B preview is a different release.</p>
        </details>
        {!api ? <p className="text-sm">Open Quenderin desktop to select and run a converted model.</p> : <>
            <button type="button" disabled={busy} onClick={() => void run(async () => {
                setStatus('Choose the converted GGUF, then wait for complete checksum verification.'); const selected = await api.chooseGraniteModel();
                if (selected && mounted.current && !cancelled.current) { setModel(selected); setMessages([]); setStatus('Converted Granite model verified.'); }
            })} className="rounded-lg border border-zinc-300 px-3 py-2 text-sm disabled:opacity-50 dark:border-zinc-700">Choose converted Granite model</button>
            {model && <p className="break-words text-sm text-zinc-500">{model.label}</p>}
            {messages.length > 0 && <div role="log" aria-label="Granite conversation" className="max-h-96 space-y-4 overflow-y-auto border-y border-zinc-200 py-3 dark:border-zinc-800">{messages.map((message, index) => <div key={index}><p className="text-xs font-semibold text-zinc-500">{message.role === 'user' ? 'You' : 'Granite'}</p><p className="mt-1 whitespace-pre-wrap break-words text-sm leading-6">{message.content}</p></div>)}</div>}
            <label className="block text-sm">Message to Granite<textarea rows={3} disabled={busy} value={draft} onChange={event => setDraft(event.target.value)} className="mt-1 block w-full rounded-lg border border-zinc-300 bg-transparent p-3 dark:border-zinc-700" /></label>
            <div className="flex flex-wrap gap-2"><button type="button" disabled={!model || busy || !draft.trim() || new TextEncoder().encode(draft).byteLength > 8192 || messages.length >= 16} onClick={() => void run(async () => {
                setStatus('Verifying and loading Granite for local text chat…'); const selected = [...messages, { role: 'user' as const, content: draft }];
                const answer = await api.answerGranite({ modelHandle: model!.handle, messages: selected });
                if (mounted.current && !cancelled.current) { setMessages([...selected, { role: 'assistant', content: answer.text }]); setDraft(''); setStatus('Reply generated locally.'); }
            })} className="rounded-lg bg-purple-600 px-4 py-2 text-sm font-medium text-white disabled:opacity-50">Ask Granite</button>
                {busy && <button type="button" onClick={() => { cancelled.current = true; setStatus('Cancelling Granite…'); void api.cancel().catch(cause => setError(String(cause))); }} className="rounded-lg border border-zinc-300 px-3 py-2 text-sm dark:border-zinc-700">Cancel Granite</button>}
                {messages.length > 0 && <button type="button" disabled={busy} onClick={() => { setMessages([]); setError(null); setStatus('New Granite conversation.'); }} className="rounded-lg border border-zinc-300 px-3 py-2 text-sm disabled:opacity-50 dark:border-zinc-700">New Granite conversation</button>}
            </div>
            <p className="text-xs text-zinc-500">Up to 8 exchanges, 32 KiB of history and 512 output tokens per request. The complete model is released after each reply.</p>
            <p role="status" className="text-sm text-zinc-600 dark:text-zinc-400">{status}</p>
            {error && <p role="alert" className="text-sm text-red-600 dark:text-red-400">{error} Your message is kept for retry.</p>}
        </>}
    </section>;
}
