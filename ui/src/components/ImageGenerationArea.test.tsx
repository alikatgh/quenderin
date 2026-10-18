import { afterEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import axe from 'axe-core';
import { ImageGenerationArea } from './ImageGenerationArea.js';
import catalog from '../../../shared/image-model-catalog.json';
import type { ImageGeneratedView, ImageGenerationProgress, ImagePresetView, ImageWorkflowAPI } from '../../../src/electron/imageWorkflowTypes.js';

const models: ImagePresetView[] = catalog.models.map(model => ({ id: model.id, label: model.label, publisher: model.publisher,
    license: model.license, licenseUrl: model.licenseUrl, requiresPublisherAccess: model.requiresPublisherAccess,
    width: 512, height: 512, steps: model.defaults.steps, totalBytes: model.components.reduce((sum, part) => sum + part.bytes, 0),
    promptRequirement: 'promptRequirement' in model ? model.promptRequirement : undefined,
    components: model.components.map(part => ({ filename: part.localFilename, role: part.role, bytes: part.bytes, license: model.license, repository: part.repo, access: part.access })) }));
const image: ImageGeneratedView = { path: '/chosen/new-image.png', width: 512, height: 512, previewDataUrl: 'data:image/png;base64,aGVsbG8=' };
function fixture() {
    let listener: ((value: ImageGenerationProgress) => void) | undefined;
    const unsubscribe = vi.fn();
    const api = {
        models: vi.fn(async () => models), chooseFolder: vi.fn(async () => ({ handle: 'opaque-folder', label: '/chosen/components' })),
        verify: vi.fn(async (_request: Parameters<ImageWorkflowAPI['verify']>[0]) => ({ model: models[0].id, components: 3, bytes: models[0].totalBytes })),
        generate: vi.fn(async (_request: Parameters<ImageWorkflowAPI['generate']>[0]) => image as ImageGeneratedView | null), cancel: vi.fn(async () => {}),
        onProgress: vi.fn((callback: (value: ImageGenerationProgress) => void) => { listener = callback; return unsubscribe; }),
    } satisfies ImageWorkflowAPI;
    return { api, unsubscribe, progress: (value: ImageGenerationProgress) => listener?.(value) };
}
const generateButton = () => screen.getByRole('button', { name: 'Generate and save PNG…' }) as HTMLButtonElement;
async function prepare() {
    const choose = screen.getByRole('button', { name: 'Choose prepared folder' }) as HTMLButtonElement;
    await waitFor(() => expect(choose.disabled).toBe(false)); fireEvent.click(choose);
    await screen.findByText('Selected folder: /chosen/components');
    fireEvent.click(screen.getByRole('button', { name: 'Verify files' }));
    await screen.findByRole('button', { name: 'Verify again' });
    fireEvent.change(screen.getByLabelText('Scene caption'), { target: { value: 'A sunlit garden with copper flowers' } });
    expect(generateButton().disabled).toBe(false);
}
afterEach(cleanup);

describe('desktop image workflow UI', () => {
    it('shows all three real presets, exact component requirements and truthful browser-only state', async () => {
        const { container } = render(<ImageGenerationArea />);
        expect(screen.getByText('Image generation requires the Quenderin desktop app.')).toBeTruthy();
        expect(screen.getAllByRole('option').map(option => option.textContent)).toEqual(catalog.models.map(model => model.label));
        const components = screen.getByText('3 required components').closest('details')!;
        expect(components.open).toBe(false);
        fireEvent.click(components.querySelector('summary')!);
        expect(components.open).toBe(true);
        for (const part of catalog.models[0].components) expect(screen.getByText(part.localFilename)).toBeTruthy();
        expect(screen.getByText(/24 GiB of available memory/u)).toBeTruthy();
        expect(screen.getByText(/Image inference has not been validated/u)).toBeTruthy();
        expect((screen.getByRole('button', { name: 'Choose prepared folder' }) as HTMLButtonElement).disabled).toBe(true);
        expect(generateButton().disabled).toBe(true);
        const audit = await axe.run(container, { rules: { 'color-contrast': { enabled: false } } });
        expect(audit.violations.map(violation => violation.id)).toEqual([]);
    });
    it('selects a folder, verifies, generates and previews only the bridge result with its saved path', async () => {
        const { api } = fixture(); render(<ImageGenerationArea api={api} />); await prepare();
        fireEvent.click(generateButton());
        const preview = await screen.findByRole('img', { name: 'Generated image from your scene caption' });
        expect(preview.getAttribute('src')).toBe(image.previewDataUrl); expect(screen.getByText(image.path)).toBeTruthy();
        expect(api.verify.mock.calls).toEqual([[{ modelId: models[0].id, folderHandle: 'opaque-folder' }]]);
        expect(api.generate.mock.calls[0][0]).toEqual({ modelId: models[0].id, folderHandle: 'opaque-folder', prompt: 'A sunlit garden with copper flowers', requestId: expect.any(String) });
    });
    it('keeps the caption after an error and retries with the same verified selection', async () => {
        const { api } = fixture(); api.generate.mockRejectedValueOnce(new Error('Pinned image runtime is missing.'));
        render(<ImageGenerationArea api={api} />); await prepare(); fireEvent.click(generateButton());
        expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'Pinned image runtime is missing.');
        expect((screen.getByLabelText('Scene caption') as HTMLTextAreaElement).value).toBe('A sunlit garden with copper flowers');
        expect(generateButton().disabled).toBe(false); fireEvent.click(generateButton());
        await screen.findByText(image.path); expect(api.generate).toHaveBeenCalledTimes(2);
    });
    it('keeps the prompt and verification when the native save dialog is cancelled', async () => {
        const { api } = fixture(); api.generate.mockResolvedValueOnce(null);
        render(<ImageGenerationArea api={api} />); await prepare(); fireEvent.click(generateButton());
        await screen.findByText('Save cancelled. Your caption and verified folder are kept.');
        expect(generateButton().disabled).toBe(false); expect(screen.queryByRole('img')).toBeNull();
    });
    it('displays actual matching progress, disables concurrent operations and cancels', async () => {
        const { api, progress } = fixture(); let reject!: (error: Error) => void;
        api.generate.mockImplementation(() => new Promise((_resolve, no) => { reject = no; }));
        render(<ImageGenerationArea api={api} />); await prepare(); fireEvent.click(generateButton());
        await waitFor(() => expect(api.generate).toHaveBeenCalled());
        expect(generateButton().disabled).toBe(true); expect((screen.getByRole('combobox') as HTMLSelectElement).disabled).toBe(true);
        act(() => progress({ requestId: 'different', step: 1, steps: 16 })); expect(screen.queryByRole('progressbar')).toBeNull();
        act(() => progress({ requestId: api.generate.mock.calls[0][0].requestId, step: 3, steps: 16 }));
        expect((screen.getByRole('progressbar', { name: 'Image generation progress' }) as HTMLProgressElement).value).toBe(3);
        fireEvent.click(screen.getByRole('button', { name: 'Cancel operation' })); expect(api.cancel).toHaveBeenCalledTimes(1);
        await act(async () => reject(new Error('Image operation cancelled.')));
        await screen.findByText('Image operation cancelled. Your caption and selection are kept.'); expect(screen.queryByRole('alert')).toBeNull();
    });
    it('cancels hidden jobs on navigation, preserves inputs, and unsubscribes on unmount', async () => {
        const { api, unsubscribe } = fixture(); let reject!: (error: Error) => void;
        api.generate.mockImplementation(() => new Promise((_resolve, no) => { reject = no; }));
        const view = render(<ImageGenerationArea api={api} active />); await prepare(); fireEvent.click(generateButton());
        await waitFor(() => expect(api.generate).toHaveBeenCalled());
        view.rerender(<ImageGenerationArea api={api} active={false} />); expect(api.cancel).toHaveBeenCalledTimes(1);
        await act(async () => reject(new Error('cancelled')));
        view.rerender(<ImageGenerationArea api={api} active />);
        expect((screen.getByLabelText('Scene caption') as HTMLTextAreaElement).value).toContain('copper flowers');
        expect(screen.getByText('Selected folder: /chosen/components')).toBeTruthy();
        view.unmount(); expect(unsubscribe).toHaveBeenCalledTimes(1);
    });
    it('cancels active work on unmount and ignores a late completion', async () => {
        const { api, unsubscribe } = fixture(); let resolve!: (result: ImageGeneratedView) => void;
        api.generate.mockImplementation(() => new Promise(yes => { resolve = yes; }));
        const view = render(<ImageGenerationArea api={api} />); await prepare(); fireEvent.click(generateButton());
        await waitFor(() => expect(api.generate).toHaveBeenCalled()); view.unmount();
        expect(api.cancel).toHaveBeenCalledTimes(1); expect(unsubscribe).toHaveBeenCalledTimes(1);
        await act(async () => resolve(image));
    });
    it('invalidates verification when the preset changes and bounds UTF-8 caption bytes', async () => {
        const { api } = fixture(); render(<ImageGenerationArea api={api} />); await prepare();
        fireEvent.change(screen.getByLabelText('Scene caption'), { target: { value: 'é'.repeat(4097) } }); expect(generateButton().disabled).toBe(true);
        fireEvent.change(screen.getByRole('combobox'), { target: { value: models[1].id } }); expect(generateButton().disabled).toBe(true);
        expect(screen.getByRole('button', { name: 'Verify files' })).toBeTruthy(); expect(api.generate).not.toHaveBeenCalled();
    });
    it('recovers catalog loading failures without discarding the caption', async () => {
        const { api } = fixture(); api.models.mockRejectedValueOnce(new Error('Catalog unavailable'));
        render(<ImageGenerationArea api={api} />); await screen.findByRole('alert');
        fireEvent.change(screen.getByLabelText('Scene caption'), { target: { value: 'Keep this caption' } });
        fireEvent.click(screen.getByRole('button', { name: 'Retry loading image presets' }));
        await waitFor(() => expect((screen.getByRole('button', { name: 'Choose prepared folder' }) as HTMLButtonElement).disabled).toBe(false));
        expect((screen.getByLabelText('Scene caption') as HTMLTextAreaElement).value).toBe('Keep this caption');
    });
});
