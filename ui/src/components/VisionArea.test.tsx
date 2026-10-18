import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { VisionArea } from './VisionArea.js';
import type { VisionWorkflowAPI } from '../../../src/electron/visionWorkflowTypes.js';

function api() {
    return { models: vi.fn(async () => [{ id: 'fixture', label: 'Vision fixture', minimumMemoryBytes: 8 * 1024 ** 3,
        artifacts: [{ role: 'model', filename: 'model.gguf', bytes: 4, url: 'https://example.invalid/model' }, { role: 'projector', filename: 'mmproj.gguf', bytes: 4, url: 'https://example.invalid/mmproj' }] }]),
    status: vi.fn(async () => ({ installed: true, availableMemoryBytes: 16 * 1024 ** 3 })), chooseImage: vi.fn(async () => ({ handle: 'opaque', label: 'photo.png' })),
    install: vi.fn(async () => {}), verify: vi.fn(async () => {}), answer: vi.fn(async () => ({ text: 'An image answer.', tokens: 4 })),
    chooseGraniteModel: vi.fn(async () => null), answerGranite: vi.fn(async () => ({ text: 'Granite fixture' })),
    cancel: vi.fn(async () => {}), onProgress: vi.fn(() => () => {}) } satisfies VisionWorkflowAPI;
}
afterEach(cleanup);
describe('local vision workflow', () => {
    it('selects an image and sends a question only through the opaque native selection', async () => {
        const bridge = api(); render(<VisionArea active api={bridge} />);
        await screen.findByText('Vision fixture'); fireEvent.click(screen.getByRole('button', { name: 'Choose image' }));
        await screen.findByText('photo.png'); fireEvent.change(screen.getByLabelText('Your question'), { target: { value: 'What is here?' } });
        fireEvent.click(screen.getByRole('button', { name: 'Ask about image' }));
        await screen.findByText('An image answer.');
        expect(bridge.answer).toHaveBeenCalledWith({ modelId: 'fixture', imageHandle: 'opaque', prompt: 'What is here?' });
    });
    it('keeps the question after a real service error for retry', async () => {
        const bridge = api(); bridge.answer.mockRejectedValueOnce(new Error('Projector checksum mismatch'));
        render(<VisionArea active api={bridge} />); await screen.findByText('Vision fixture');
        fireEvent.click(screen.getByRole('button', { name: 'Choose image' })); await screen.findByText('photo.png');
        fireEvent.change(screen.getByLabelText('Your question'), { target: { value: 'Keep this question' } });
        fireEvent.click(screen.getByRole('button', { name: 'Ask about image' }));
        await screen.findByRole('alert'); expect((screen.getByLabelText('Your question') as HTMLTextAreaElement).value).toBe('Keep this question');
        expect(screen.getByRole('alert').textContent).toContain('Projector checksum mismatch');
    });
    it('cancels a pending operation when leaving the view', async () => {
        const bridge = api(); let finish!: () => void;
        bridge.install.mockImplementation(() => new Promise<void>(resolve => { finish = resolve; }));
        const view = render(<VisionArea active api={bridge} />); await screen.findByText('Vision fixture');
        fireEvent.click(screen.getByRole('button', { name: 'Check installation' }));
        await waitFor(() => expect(bridge.install).toHaveBeenCalled()); view.rerender(<VisionArea active={false} api={bridge} />);
        await waitFor(() => expect(bridge.cancel).toHaveBeenCalled()); finish();
        await screen.findByText(/operation cancelled/);
    });
});
