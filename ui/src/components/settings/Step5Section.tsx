import { useEffect, useRef, useState } from 'react';
import { apiFetch } from '../../lib/api.js';

type Message = { role: 'user' | 'assistant'; content: string };
// Deliberately session-only: navigation preserves a draft, relaunch does not persist prompts or hosts.
const session: { endpoint: string; draft: string; messages: Message[] } = { endpoint: 'http://127.0.0.1:18000', draft: '', messages: [] };

export function Step5Section() {
    const [endpoint, setEndpoint] = useState(session.endpoint);
    const [draft, setDraft] = useState(session.draft);
    const [messages, setMessages] = useState<Message[]>(session.messages);
    const [consent, setConsent] = useState(false);
    const [busy, setBusy] = useState(false);
    const [status, setStatus] = useState('Connect an already installed official Step 5 CUDA backend.');
    const [error, setError] = useState<string | null>(null);
    const operation = useRef<AbortController | null>(null);
    useEffect(() => { session.endpoint = endpoint; session.draft = draft; session.messages = messages; }, [endpoint, draft, messages]);
    useEffect(() => () => { operation.current?.abort(); }, []);

    async function run(action: 'check' | 'answer') {
        if (operation.current || !consent) return;
        const controller = new AbortController(); operation.current = controller; setBusy(true); setError(null);
        const selected = [...messages, { role: 'user' as const, content: draft }];
        try {
            setStatus(action === 'check' ? 'Checking the pinned backend and complete artifact set…' : 'Waiting for Step 5 on your CUDA host…');
            const response = await apiFetch(`/api/step5/${action}`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ endpoint, consent, ...(action === 'answer' ? { messages: selected } : {}) }), signal: controller.signal });
            const result = await response.json();
            if (!response.ok) throw new Error(result.error || 'Step 5 request failed.');
            if (controller.signal.aborted) return;
            if (action === 'answer') {
                if (typeof result.text !== 'string') throw new Error('The backend returned no answer.');
                setMessages([...selected, { role: 'assistant', content: result.text }]); setDraft('');
                setStatus(result.truncated ? 'Reply reached the 1,024-token limit. No automatic continuation was requested.' : 'Reply received from your Step 5 backend.');
            } else setStatus('The pinned Step 5 backend is ready.');
        } catch (cause) {
            if (!controller.signal.aborted) { setError(cause instanceof Error ? cause.message : 'Step 5 request failed.'); setStatus('Ready to retry. Your prompt and conversation are kept.'); }
            else setStatus('Request cancelled. Your prompt and conversation are kept.');
        } finally { if (operation.current === controller) operation.current = null; setBusy(false); }
    }
    const bytes = new TextEncoder().encode(draft).byteLength;
    const full = messages.length >= 16;
    return <section aria-labelledby="step5-heading" className="space-y-4 rounded-xl border border-zinc-200 p-5 dark:border-zinc-800">
        <div><h2 id="step5-heading" className="font-semibold">Step 5 Preview</h2>
            <p className="mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-400">Chat through the official Step 5 CUDA runtime on your own host. This model needs a large GPU server and runs there. Other Quenderin models continue to run on your device.</p></div>
        <details className="text-sm text-zinc-600 dark:text-zinc-400"><summary className="cursor-pointer">Prepare your backend</summary>
            <p className="mt-2 leading-6">Run <code>scripts/run_step5_backend.py</code> with your installed pinned vLLM source and complete FP8 checkpoint. It verifies every required artifact, disables network downloads, and allows one request at a time. Connect through a local SSH tunnel or your secured HTTPS reverse proxy. Quenderin does not provision a server.</p>
        </details>
        <label className="block text-sm">Your gateway URL<input aria-label="Step 5 gateway URL" value={endpoint} disabled={busy} onChange={event => { setEndpoint(event.target.value); setConsent(false); }}
            className="mt-1 block w-full rounded-lg border border-zinc-300 bg-transparent p-2 dark:border-zinc-700" placeholder="http://127.0.0.1:18000" autoComplete="off" spellCheck={false} /></label>
        <label className="flex items-start gap-2 text-sm"><input type="checkbox" checked={consent} disabled={busy} onChange={event => setConsent(event.target.checked)} className="mt-1" />
            I want to send this conversation to the CUDA host at this address.</label>
        <button type="button" disabled={!consent || busy} onClick={() => void run('check')} className="rounded-lg border border-zinc-300 px-3 py-2 text-sm disabled:opacity-50 dark:border-zinc-700">Check connection</button>
        {messages.length > 0 && <div role="log" aria-label="Step 5 conversation" className="max-h-96 space-y-4 overflow-y-auto border-y border-zinc-200 py-3 dark:border-zinc-800">
            {messages.map((message, index) => <div key={index}><p className="text-xs font-semibold text-zinc-500">{message.role === 'user' ? 'You' : 'Step 5'}</p><p className="mt-1 whitespace-pre-wrap break-words text-sm leading-6">{message.content}</p></div>)}
        </div>}
        <label className="block text-sm">Message<textarea value={draft} disabled={busy || full} onChange={event => setDraft(event.target.value)} rows={3}
            className="mt-1 w-full rounded-lg border border-zinc-300 bg-transparent p-3 dark:border-zinc-700" /></label>
        <p className="text-xs text-zinc-500">{bytes.toLocaleString()} / 8,192 bytes. Up to 8 exchanges, 32 KiB of selected history, and 1,024 output tokens per request.</p>
        {full && <p className="text-sm">This conversation is full. Start a new conversation to continue.</p>}
        <div className="flex flex-wrap gap-2">
            <button type="button" disabled={!consent || busy || full || !draft.trim() || bytes > 8192} onClick={() => void run('answer')} className="rounded-lg bg-purple-600 px-4 py-2 text-sm font-medium text-white disabled:opacity-50">Send to Step 5</button>
            {busy && <button type="button" onClick={() => operation.current?.abort()} className="rounded-lg border border-zinc-300 px-3 py-2 text-sm dark:border-zinc-700">Cancel request</button>}
            {messages.length > 0 && <button type="button" disabled={busy} onClick={() => { setMessages([]); setError(null); setStatus('New Step 5 conversation.'); }} className="rounded-lg border border-zinc-300 px-3 py-2 text-sm disabled:opacity-50 dark:border-zinc-700">New conversation</button>}
        </div>
        <p role="status" className="text-sm text-zinc-600 dark:text-zinc-400">{status}</p>
        {error && <p role="alert" className="text-sm text-red-600 dark:text-red-400">{error} Your prompt is kept for retry.</p>}
    </section>;
}
