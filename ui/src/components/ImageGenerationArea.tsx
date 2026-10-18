import { useEffect, useRef, useState } from 'react';
import { FolderOpen, Image as ImageIcon, Loader2, ShieldCheck, Square, WandSparkles } from 'lucide-react';
import catalog from '../../../shared/image-model-catalog.json';
import type { ImageFolderSelection, ImageGeneratedView, ImageGenerationProgress, ImagePresetView, ImageWorkflowAPI } from '../../../src/electron/imageWorkflowTypes.js';

const browserPresets: ImagePresetView[] = catalog.models.map(model => ({
    id: model.id, label: model.label, publisher: model.publisher, license: model.license, licenseUrl: model.licenseUrl,
    requiresPublisherAccess: model.requiresPublisherAccess,
    promptRequirement: 'promptRequirement' in model ? model.promptRequirement : undefined,
    width: model.defaults.width, height: model.defaults.height, steps: model.defaults.steps,
    totalBytes: model.components.reduce((total, component) => total + component.bytes, 0),
    components: model.components.map(component => ({ filename: component.localFilename, role: component.role,
        bytes: component.bytes, repository: component.repo, access: component.access,
        license: 'license' in component ? component.license! : model.license })),
}));
const focus = 'focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-purple-500';
const secondary = `inline-flex items-center justify-center gap-2 rounded-lg border border-zinc-300 dark:border-zinc-700 px-3 py-2 text-[13px] font-medium hover:bg-zinc-100 dark:hover:bg-zinc-800 disabled:opacity-50 disabled:cursor-not-allowed ${focus}`;
const bytesLabel = (bytes: number) => `${bytes.toLocaleString('en-US')} bytes · ${(bytes / 1024 ** 3).toFixed(2)} GiB`;
const errorText = (error: unknown) => (error instanceof Error ? error.message : 'Image operation failed. Try again.').slice(0, 2048);

interface Props { active?: boolean; api?: ImageWorkflowAPI }

/** Kept mounted by App so captions and selections survive navigation. Leaving cancels active work. */
export function ImageGenerationArea({ active = true, api = (window as Window & { quenderinImages?: ImageWorkflowAPI }).quenderinImages }: Props) {
    const [presets, setPresets] = useState(browserPresets);
    const [modelsReady, setModelsReady] = useState(!api);
    const [modelId, setModelId] = useState(browserPresets[0].id);
    const [folder, setFolder] = useState<ImageFolderSelection | null>(null);
    const [verified, setVerified] = useState(false);
    const [prompt, setPrompt] = useState('');
    const [busy, setBusy] = useState<'folder' | 'verify' | 'generate' | null>(null);
    const [cancelling, setCancelling] = useState(false);
    const [status, setStatus] = useState('Choose a prepared model folder, then verify every required component.');
    const [error, setError] = useState<string | null>(null);
    const [progress, setProgress] = useState<ImageGenerationProgress | null>(null);
    const [result, setResult] = useState<ImageGeneratedView | null>(null);
    const heading = useRef<HTMLHeadingElement>(null);
    const mounted = useRef(false);
    const busyRef = useRef(false);
    const cancelRequested = useRef(false);
    const requestId = useRef<string | null>(null);
    const selected = presets.find(model => model.id === modelId) ?? presets[0];
    const promptBytes = new TextEncoder().encode(prompt).byteLength;
    const validPrompt = prompt.trim().length > 0 && promptBytes <= 8192 && !prompt.includes('\0');

    const loadModels = () => {
        if (!api) return;
        setError(null);
        setModelsReady(false);
        void api.models().then(models => {
            if (!mounted.current) return;
            if (models.length !== 3) throw new Error('The desktop image catalog is unavailable. Relaunch the app.');
            setPresets(models);
            setModelsReady(true);
        }).catch(cause => { if (mounted.current) setError(errorText(cause)); });
    };

    useEffect(() => {
        mounted.current = true;
        loadModels();
        const unsubscribe = api?.onProgress(update => {
            if (mounted.current && requestId.current === update.requestId && !cancelRequested.current) {
                setProgress(update);
                setStatus(`Generating: step ${update.step} of ${update.steps}.`);
            }
        });
        return () => {
            mounted.current = false;
            unsubscribe?.();
            if (busyRef.current) { cancelRequested.current = true; void api?.cancel().catch(() => {}); }
        };
        // The bridge is fixed for the lifetime of this mounted workflow.
    }, [api]);

    const cancel = () => {
        if (!api || !busyRef.current || cancelRequested.current) return;
        cancelRequested.current = true;
        setCancelling(true);
        setStatus('Cancelling image operation…');
        void api.cancel().catch(cause => { if (mounted.current) setError(errorText(cause)); });
    };
    useEffect(() => {
        if (active) heading.current?.focus();
        else cancel();
    }, [active]);

    async function run(kind: 'folder' | 'verify' | 'generate', work: () => Promise<void>) {
        if (!api || busyRef.current || !modelsReady) return;
        busyRef.current = true;
        cancelRequested.current = false;
        setBusy(kind);
        setCancelling(false);
        setError(null);
        setProgress(null);
        try { await work(); }
        catch (cause) {
            if (mounted.current) {
                if (cancelRequested.current) setStatus('Image operation cancelled. Your caption and selection are kept.');
                else { setError(errorText(cause)); setStatus('Image operation failed. Check the error and retry.'); }
            }
        } finally {
            busyRef.current = false;
            requestId.current = null;
            if (mounted.current) {
                setBusy(null); setCancelling(false);
                if (cancelRequested.current) setStatus('Image operation cancelled. Your caption and selection are kept.');
            }
        }
    }

    const chooseFolder = () => void run('folder', async () => {
        setStatus('Choose the prepared model folder in the native dialog.');
        const selection = await api!.chooseFolder();
        if (!mounted.current) return;
        if (selection) { setFolder(selection); setVerified(false); setStatus('Folder selected. Verify the complete component set before generating.'); }
        else setStatus('Folder selection cancelled. Your previous selection is kept.');
    });
    const verify = () => void run('verify', async () => {
        setVerified(false);
        setStatus('Verifying exact file sizes and SHA-256 hashes. Large components can take several minutes.');
        const check = await api!.verify({ modelId, folderHandle: folder!.handle });
        if (!mounted.current || cancelRequested.current) return;
        setVerified(true);
        setStatus(`Verified ${check.components} components (${bytesLabel(check.bytes)}). Files are checked again before generation.`);
    });
    const generate = () => void run('generate', async () => {
        requestId.current = crypto.randomUUID();
        setStatus('Choose a new PNG filename, then Quenderin will check memory, files and runtime. Existing files are preserved.');
        const image = await api!.generate({ modelId, folderHandle: folder!.handle, prompt, requestId: requestId.current! });
        if (!mounted.current || cancelRequested.current) return;
        if (image) { setResult(image); setStatus('Image saved. The preview below is the verified PNG from disk.'); }
        else setStatus('Save cancelled. Your caption and verified folder are kept.');
    });

    return (
        <section aria-labelledby="images-title" className="flex-1 min-h-0 overflow-y-auto px-4 py-6 sm:px-6">
            <div className="mx-auto max-w-5xl space-y-5">
                <div>
                    <h1 id="images-title" ref={heading} tabIndex={-1} className="text-xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-100 outline-none">Images</h1>
                    <p className="mt-1 text-[13px] leading-6 text-zinc-600 dark:text-zinc-400">Generate a PNG locally from a scene caption and a prepared component folder.</p>
                </div>
                <div className="border-l-2 border-amber-500 pl-3 text-[12px] leading-5 text-zinc-600 dark:text-zinc-400">
                    <p><strong className="font-semibold text-zinc-800 dark:text-zinc-200">Experimental source integration.</strong> Image inference has not been validated with model weights.</p>
                    <p>Requires at least 24 GiB of available memory, sufficient disk space and the pinned image runtime. Generation stops after 15 minutes.</p>
                </div>
                {!api && <div role="note" className="rounded-lg border border-zinc-300 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-900 p-4 text-[13px] leading-6">
                    <strong className="font-semibold">Image generation requires the Quenderin desktop app.</strong> This browser dashboard can show the presets. Folder selection, verification and local generation are available inside the Electron app.
                </div>}
                <div className="grid gap-6 lg:grid-cols-[minmax(0,1.1fr)_minmax(0,1fr)]">
                    <div className="min-w-0 space-y-5">
                        <div>
                            <label htmlFor="image-preset" className="block text-[13px] font-semibold mb-2">Image model</label>
                            <select id="image-preset" value={modelId} disabled={!!busy} onChange={event => { setModelId(event.target.value); setVerified(false); setError(null); }} className={`w-full rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 px-3 py-2 text-[13px] ${focus}`}>
                                {presets.map(model => <option key={model.id} value={model.id}>{model.label}</option>)}
                            </select>
                            <p className="mt-2 text-[12px] text-zinc-600 dark:text-zinc-400">{selected.publisher} · {selected.license} · {selected.width} × {selected.height} PNG · {selected.steps} steps</p>
                            <p className="mt-1 text-[12px] leading-5 text-zinc-600 dark:text-zinc-400">{selected.requiresPublisherAccess ? 'Publisher access is required. Obtain the files yourself after reviewing and accepting the publisher’s terms.' : 'Public components. Review the model and component licenses before use.'} Quenderin does not download files or accept terms here.</p>
                            <details className="mt-2 text-[12px] text-zinc-500 dark:text-zinc-400">
                                <summary className={`cursor-pointer w-fit ${focus}`}>Publisher license source</summary>
                                <p className="mt-1 break-all select-text">{selected.licenseUrl}</p>
                            </details>
                        </div>
                        <details className="border-y border-zinc-200 dark:border-zinc-800 py-2.5">
                            <summary className={`cursor-pointer text-[12px] leading-5 text-zinc-600 dark:text-zinc-400 ${focus}`}><span className="font-semibold text-zinc-900 dark:text-zinc-100">{selected.components.length} required components</span> · {bytesLabel(selected.totalBytes)}</summary>
                            <p className="mt-2 text-[12px] text-zinc-500 dark:text-zinc-400">Place every file directly inside one prepared folder.</p>
                            <ul className="mt-2 divide-y divide-zinc-200 dark:divide-zinc-800 border-y border-zinc-200 dark:border-zinc-800">
                                {selected.components.map(component => <li key={component.filename} className="py-2.5 text-[11px] leading-5">
                                    <p className="font-mono break-all text-zinc-800 dark:text-zinc-200">{component.filename}</p>
                                    <p className="text-zinc-600 dark:text-zinc-400">{bytesLabel(component.bytes)} · {component.license} · {component.access === 'publisher-gated' ? 'Publisher access required' : 'Public access'}</p>
                                    <p className="text-zinc-500 dark:text-zinc-500 break-all">{component.repository} · {component.role.replace(/_/gu, ' ')}</p>
                                </li>)}
                            </ul>
                        </details>
                        <div className="space-y-2">
                            <div className="flex flex-wrap gap-2">
                                <button type="button" onClick={chooseFolder} disabled={!api || !modelsReady || !!busy} className={secondary}><FolderOpen aria-hidden="true" className="h-4 w-4" />Choose prepared folder</button>
                                <button type="button" onClick={verify} disabled={!api || !modelsReady || !folder || !!busy} className={secondary}><ShieldCheck aria-hidden="true" className="h-4 w-4" />{verified ? 'Verify again' : 'Verify files'}</button>
                            </div>
                            <p className="break-all text-[12px] text-zinc-500 dark:text-zinc-400">{folder ? `Selected folder: ${folder.label}` : 'No folder selected.'}</p>
                        </div>
                        <div>
                            <label htmlFor="image-caption" className="block text-[13px] font-semibold mb-2">Scene caption</label>
                            <textarea id="image-caption" value={prompt} maxLength={8192} disabled={!!busy} onChange={event => setPrompt(event.target.value)} rows={4} aria-describedby="image-caption-help image-caption-limit" placeholder="Describe the subject, setting, light and composition…" className={`w-full resize-y min-h-28 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 px-3 py-2.5 text-[13px] leading-6 placeholder:text-zinc-400 dark:placeholder:text-zinc-600 ${focus}`} />
                            <p id="image-caption-help" className="mt-1 text-[12px] leading-5 text-zinc-500 dark:text-zinc-400">{selected.promptRequirement ? 'For FLUX 3, paste a full scene caption expanded with your local text model. Reference image inputs are not available in this desktop workflow.' : 'Describe the complete image you want to generate.'}</p>
                            <p id="image-caption-limit" className={`mt-1 text-[11px] tabular-nums ${promptBytes > 8192 ? 'text-red-600 dark:text-red-400' : 'text-zinc-500 dark:text-zinc-400'}`}>{promptBytes.toLocaleString('en-US')} / 8,192 UTF-8 bytes</p>
                        </div>
                        <div className="flex flex-wrap gap-2">
                            <button type="button" onClick={generate} disabled={!api || !modelsReady || !verified || !folder || !validPrompt || !!busy} className={`inline-flex items-center justify-center gap-2 rounded-lg bg-purple-600 hover:bg-purple-500 px-4 py-2.5 text-[13px] font-semibold text-white disabled:opacity-50 disabled:cursor-not-allowed ${focus}`}><WandSparkles aria-hidden="true" className="w-4 h-4" />Generate and save PNG…</button>
                            {busy && <button type="button" onClick={cancel} disabled={cancelling} className={secondary}><Square aria-hidden="true" className="h-3.5 w-3.5" />{cancelling ? 'Cancelling…' : 'Cancel operation'}</button>}
                        </div>
                        <div role="status" aria-live="polite" className="text-[12px] leading-5 text-zinc-600 dark:text-zinc-400">
                            <p className="flex items-start gap-2">{busy && <Loader2 aria-hidden="true" className="h-4 w-4 shrink-0 mt-0.5 motion-safe:animate-spin" />}{status}</p>
                            {progress && busy === 'generate' && <progress aria-label="Image generation progress" value={progress.step} max={progress.steps} className="mt-2 w-full accent-purple-600" />}
                        </div>
                        {error && <div role="alert" className="text-[12px] leading-5 text-red-700 dark:text-red-400 break-words"><p>{error}</p>{!modelsReady && api && <button type="button" onClick={loadModels} className={`mt-2 underline underline-offset-2 ${focus}`}>Retry loading image presets</button>}</div>}
                    </div>
                    <div className="min-w-0">
                        <div className="lg:sticky lg:top-0">
                            <h2 className="text-[13px] font-semibold mb-3">{result ? 'Last saved image' : 'PNG preview'}</h2>
                            {result ? <figure>
                                <img src={result.previewDataUrl} alt="Generated image from your scene caption" width={result.width} height={result.height} className="block w-full h-auto rounded-lg border border-zinc-200 dark:border-zinc-800" />
                                <figcaption className="mt-3 text-[12px] leading-5 text-zinc-500 dark:text-zinc-400">Verified {result.width} × {result.height} PNG saved to:<span className="block mt-1 break-all select-text text-zinc-700 dark:text-zinc-300">{result.path}</span></figcaption>
                            </figure> : <div className="aspect-square rounded-lg border border-dashed border-zinc-300 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-900/40 flex flex-col items-center justify-center gap-3 px-8 text-center text-zinc-500 dark:text-zinc-400">
                                <ImageIcon aria-hidden="true" className="w-7 h-7 text-zinc-400 dark:text-zinc-600" />
                                <p className="text-[13px] leading-6">Your saved PNG will appear here after generation and validation.</p>
                            </div>}
                        </div>
                    </div>
                </div>
            </div>
        </section>
    );
}
