import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { HyMemorySection } from './HyMemorySection.js';

const proposals = [{ id: 'proposal-1', text: 'I prefer tea', saved: false }, { id: 'proposal-2', text: 'I live in Paris', saved: false }];
let current: object, calls: { url: string; body?: Record<string, unknown> }[], fail: boolean;
beforeEach(() => {
    current = { installed: true, availableMemoryBytes: 34_359_738_368, requiredMemoryBytes: 34_359_738_368, downloadBytes: 18_236_702_240, unavailableReason: null, busy: false, progress: 0, proposals: [] };
    calls = []; fail = false;
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = String(input), body = init?.body ? JSON.parse(String(init.body)) : undefined; calls.push({ url, body });
        if (url.endsWith('/status')) return new Response(JSON.stringify(current), { status: 200 });
        if (url.endsWith('/propose')) {
            if (fail) return new Response(JSON.stringify({ error: 'Test specialist unavailable' }), { status: 400 });
            current = { ...current, batchId: 'batch-1', proposals }; return new Response(JSON.stringify({ batchId: 'batch-1', proposals }));
        }
        if (url.endsWith('/approve')) { current = { ...current, batchId: 'batch-1', proposals: proposals.map(proposal => ({ ...proposal, saved: body.proposalIds.includes(proposal.id) })) }; }
        return new Response('{}');
    }));
});
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });
const preview = () => screen.getByRole('button', { name: 'Preview memory proposals' }) as HTMLButtonElement;
async function propose() {
    render(<HyMemorySection />);
    fireEvent.change(screen.getByLabelText('Selected conversation'), { target: { value: 'User: I prefer tea.' } });
    await waitFor(() => expect(preview().disabled).toBe(false)); fireEvent.click(preview());
    await screen.findByText('I prefer tea');
}
describe('Hy-Memory explicit proposal approval UI', () => {
    it('allows an eligible machine to release idle text weights before the live memory check', async () => {
        current = { ...current, availableMemoryBytes: 28 * 1024 ** 3, totalMemoryBytes: 48 * 1024 ** 3 };
        await propose();
        expect(calls.some(call => call.url.endsWith('/propose'))).toBe(true);
        expect(screen.getByText(/idle answer model is released/)).toBeDefined();
    });
    it('previews unchecked proposals and saves only the selected server IDs after explicit approval', async () => {
        await propose(); const checkboxes = screen.getAllByRole('checkbox') as HTMLInputElement[];
        expect(checkboxes.every(checkbox => !checkbox.checked)).toBe(true); expect(calls.some(call => call.url.endsWith('/approve'))).toBe(false);
        fireEvent.click(checkboxes[1]); fireEvent.click(screen.getByRole('button', { name: 'Save 1 selected memory privately' }));
        await screen.findByText('Saved'); expect(calls.find(call => call.url.endsWith('/approve'))?.body).toEqual({ batchId: 'batch-1', proposalIds: ['proposal-2'] });
    });
    it('retains the selected conversation on runtime failure and retry', async () => {
        fail = true; render(<HyMemorySection />); fireEvent.change(screen.getByLabelText('Selected conversation'), { target: { value: 'Keep this input' } });
        await waitFor(() => expect(preview().disabled).toBe(false)); fireEvent.click(preview()); await screen.findByText('Test specialist unavailable');
        expect((screen.getByLabelText('Selected conversation') as HTMLTextAreaElement).value).toBe('Keep this input');
        fail = false; fireEvent.click(preview()); await screen.findByText('I prefer tea');
    });
    it('explains memory/runtime gating and never starts installation when unavailable', async () => {
        current = { ...current, installed: false, unavailableReason: 'Pinned specialist runtime is unavailable' };
        render(<HyMemorySection />); await screen.findByText('Pinned specialist runtime is unavailable');
        expect((screen.getByRole('button', { name: /Install Hy-Memory specialist/u }) as HTMLButtonElement).disabled).toBe(true);
        expect(calls.some(call => call.url.endsWith('/install'))).toBe(false);
    });
});
