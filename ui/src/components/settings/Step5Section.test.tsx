import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Step5Section } from './Step5Section.js';
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });
const send = () => screen.getByRole('button', { name: 'Send to Step 5' }) as HTMLButtonElement;
describe('Step 5 explicit host consent and retry', () => {
    it('requires consent for the selected endpoint and retains a failed draft across navigation', async () => {
        const fetch = vi.fn(async (_url: RequestInfo | URL, _init?: RequestInit) => new Response(JSON.stringify({ error: 'Synthetic backend unavailable' }), { status: 503 }));
        vi.stubGlobal('fetch', fetch);
        const view = render(<Step5Section />);
        fireEvent.change(screen.getByLabelText('Message'), { target: { value: 'Keep this selected prompt' } });
        expect(send().disabled).toBe(true); expect(fetch).not.toHaveBeenCalled();
        fireEvent.click(screen.getByRole('checkbox')); fireEvent.click(send());
        await screen.findByRole('alert');
        expect((screen.getByLabelText('Message') as HTMLTextAreaElement).value).toBe('Keep this selected prompt');
        expect(JSON.parse(fetch.mock.calls[0][1]!.body as string)).toMatchObject({ consent: true, messages: [{ role: 'user', content: 'Keep this selected prompt' }] });
        fireEvent.change(screen.getByLabelText('Step 5 gateway URL'), { target: { value: 'https://new-host.invalid' } });
        expect((screen.getByRole('checkbox') as HTMLInputElement).checked).toBe(false); expect(send().disabled).toBe(true);
        view.unmount(); render(<Step5Section />);
        expect((screen.getByLabelText('Message') as HTMLTextAreaElement).value).toBe('Keep this selected prompt');
    });
    it('cancels a blocked request and keeps the current message for retry', async () => {
        vi.stubGlobal('fetch', vi.fn((_url: unknown, init: RequestInit) => new Promise((_resolve, reject) => {
            init.signal!.addEventListener('abort', () => reject(new Error('Synthetic cancellation')), { once: true });
        })));
        render(<Step5Section />); fireEvent.change(screen.getByLabelText('Message'), { target: { value: 'Keep after cancellation' } });
        fireEvent.click(screen.getByRole('checkbox')); fireEvent.click(send());
        fireEvent.click(await screen.findByRole('button', { name: 'Cancel request' }));
        await screen.findByText('Request cancelled. Your prompt and conversation are kept.');
        await waitFor(() => expect(send().disabled).toBe(false));
        expect((screen.getByLabelText('Message') as HTMLTextAreaElement).value).toBe('Keep after cancellation');
    });
});
