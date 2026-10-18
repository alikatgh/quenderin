import { useEffect, useRef, useState } from 'react';
import type { VisionModelView, VisionSelection, VisionWorkflowAPI } from '../../../src/electron/visionWorkflowTypes.js';

export function VisionArea({ active, api = (window as Window & { quenderinVision?: VisionWorkflowAPI }).quenderinVision }: { active: boolean; api?: VisionWorkflowAPI }) {
    const [models, setModels] = useState<VisionModelView[]>([]), [modelId, setModelId] = useState('');
    const [image, setImage] = useState<VisionSelection | null>(null), [prompt, setPrompt] = useState('');
    const [result, setResult] = useState<string | null>(null), [installed, setInstalled] = useState(false);
    const [busy, setBusy] = useState(false), [progress, setProgress] = useState<number | null>(null);
    const [status, setStatus] = useState('Choose a model and one still image.'), [error, setError] = useState<string | null>(null);
    const busyRef = useRef(false), mounted = useRef(false), cancelRequested = useRef(false);
    const heading = useRef<HTMLHeadingElement>(null);
    const selected = models.find(model => model.id === modelId);
    useEffect(() => {
        mounted.current = true;
        void api?.models().then(items => { if (mounted.current) { setModels(items); setModelId(items[0]?.id ?? ''); } }).catch(cause => { if (mounted.current) setError(String(cause)); });
        const unsubscribe = api?.onProgress(update => { if (mounted.current && busyRef.current) setProgress(update.fraction); });
        return () => { mounted.current = false; unsubscribe?.(); if (busyRef.current) void api?.cancel().catch(() => {}); };
    }, [api]);
    useEffect(() => {
        if (!modelId || !api) return;
        let current = true; setInstalled(false);
        void api.status(modelId).then(state => { if (current) setInstalled(state.installed); }).catch(cause => { if (current) setError(String(cause)); });
        return () => { current = false; };
    }, [modelId, api]);
    useEffect(() => {
        if (active) heading.current?.focus();
        else if (busyRef.current) { cancelRequested.current = true; void api?.cancel().catch(() => {}); }
    }, [active, api]);
    async function run(work: () => Promise<void>) {
        if (!api || busyRef.current) return;
        busyRef.current = true; cancelRequested.current = false; setBusy(true); setError(null); setProgress(null);
        try { await work(); }
        catch (cause) { if (mounted.current && !cancelRequested.current) { setError(cause instanceof Error ? cause.message : 'Vision operation failed.'); setStatus('Ready to retry. Your question and image are kept.'); } }
        finally { busyRef.current = false; if (mounted.current) { setBusy(false); if (cancelRequested.current) setStatus('Vision operation cancelled. Your question and selected image are kept.'); } }
    }
    const bytes = new TextEncoder().encode(prompt).byteLength;
    return <section aria-labelledby="vision-title" className="flex-1 overflow-y-auto px-4 py-6 sm:px-6"><div className="mx-auto max-w-3xl space-y-5">
        <div><h1 id="vision-title" ref={heading} tabIndex={-1} className="text-xl font-semibold tracking-tight outline-none">Ask about an image</h1>
            <p className="mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-400">MiniCPM-V 4.7 and Nemotron Super VL answer questions about a still image locally. Each request uses the complete language model and its matching projector. Video input is unavailable.</p></div>
        {!api ? <p role="status" className="text-sm">Open the Quenderin desktop app to install and run local vision models.</p> : <>
            <label className="block text-sm font-medium">Vision model<select value={modelId} disabled={busy} onChange={event => { setModelId(event.target.value); setResult(null); setError(null); }} className="mt-2 block w-full rounded-lg border border-zinc-300 bg-white p-3 dark:border-zinc-700 dark:bg-zinc-900">
                {models.map(model => <option key={model.id} value={model.id}>{model.label}</option>)}
            </select></label>
            {selected && <div className="space-y-3 text-sm text-zinc-600 dark:text-zinc-400">
                <p>{(selected.artifacts.reduce((sum, part) => sum + part.bytes, 0) / 1e9).toFixed(2)} GB download · {Math.ceil(selected.minimumMemoryBytes / 1024 ** 3)} GiB available memory required</p>
                <details><summary className="cursor-pointer">Complete artifact set</summary><ul className="mt-2 space-y-2 break-words">{selected.artifacts.map(part => <li key={part.role}>{part.filename} · {part.bytes.toLocaleString()} bytes</li>)}</ul></details>
                <div className="flex flex-wrap gap-2">
                    <button type="button" disabled={busy} onClick={() => void run(async () => {
                        setStatus('Installing the pinned model and projector. Interrupted downloads can resume.'); await api.install(modelId);
                        if (!cancelRequested.current && mounted.current) { setInstalled(true); setStatus('The complete model and projector are installed and verified.'); }
                    })} className="rounded-lg border border-zinc-300 px-3 py-2 disabled:opacity-50 dark:border-zinc-700">{installed ? 'Check installation' : 'Install complete model'}</button>
                    {installed && <button type="button" disabled={busy} onClick={() => void run(async () => { setStatus('Verifying complete SHA-256 hashes…'); await api.verify(modelId); if (!cancelRequested.current && mounted.current) setStatus('Complete artifact set verified.'); })} className="rounded-lg border border-zinc-300 px-3 py-2 disabled:opacity-50 dark:border-zinc-700">Verify files</button>}
                </div>
            </div>}
            <div className="border-t border-zinc-200 pt-5 dark:border-zinc-800">
                <button type="button" disabled={busy} onClick={() => void run(async () => { const selection = await api.chooseImage(); if (selection && !cancelRequested.current && mounted.current) { setImage(selection); setResult(null); } })} className="rounded-lg border border-zinc-300 px-3 py-2 text-sm disabled:opacity-50 dark:border-zinc-700">Choose image</button>
                <p className="mt-2 text-sm text-zinc-500">{image?.label ?? 'One JPEG or PNG, up to 8 MiB and 4,096 pixels per side.'}</p>
            </div>
            <label className="block text-sm font-medium">Your question<textarea rows={4} value={prompt} disabled={busy} onChange={event => setPrompt(event.target.value)} placeholder="What is happening in this image?" className="mt-2 block w-full rounded-lg border border-zinc-300 bg-transparent p-3 font-normal dark:border-zinc-700" /></label>
            <p className="text-xs text-zinc-500">{bytes.toLocaleString()} / 8,192 bytes. One image question per request; up to 512 output tokens.</p>
            <div className="flex flex-wrap gap-2"><button type="button" disabled={busy || !installed || !image || !prompt.trim() || bytes > 8192} onClick={() => void run(async () => {
                setStatus('Verifying and loading the complete vision model…'); const answer = await api.answer({ modelId, imageHandle: image!.handle, prompt });
                if (!cancelRequested.current && mounted.current) { setResult(answer.text); setStatus(`Answered locally (${answer.tokens} output tokens).`); }
            })} className="rounded-lg bg-purple-600 px-4 py-2 text-sm font-medium text-white disabled:opacity-50">Ask about image</button>
                {busy && <button type="button" onClick={() => { cancelRequested.current = true; setStatus('Cancelling vision operation…'); void api.cancel().catch(cause => setError(String(cause))); }} className="rounded-lg border border-zinc-300 px-3 py-2 text-sm dark:border-zinc-700">Cancel</button>}</div>
            {busy && progress !== null && <progress aria-label="Vision model installation" value={progress} max={1} className="w-full accent-purple-600" />}
            <p role="status" className="text-sm text-zinc-600 dark:text-zinc-400">{status}</p>
            {error && <p role="alert" className="text-sm text-red-600 dark:text-red-400">{error} Your question is kept for retry.</p>}
            {result && <div className="border-t border-zinc-200 pt-4 dark:border-zinc-800"><h2 className="text-sm font-semibold">Answer</h2><p className="mt-2 whitespace-pre-wrap break-words text-sm leading-7">{result}</p></div>}
        </>}
    </div></section>;
}
