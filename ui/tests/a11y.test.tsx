import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import axe from 'axe-core';
import { RetryState } from '../src/components/RetryState.js';
import { ModelManagerSection } from '../src/components/settings/ModelManagerSection.js';
import { NotesSection } from '../src/components/settings/NotesSection.js';
import { MemorySection } from '../src/components/settings/MemorySection.js';

/**
 * r11 (last open item): automated a11y — axe-core over the rendered components, in CI.
 * jsdom has no layout engine, so the color-contrast rule is disabled here (it needs real
 * pixels; contrast stays covered by the manual spot-checks recorded in the r11 report).
 * Everything else axe checks — roles, names, aria wiring, button semantics — runs for real.
 */
async function expectNoAxeViolations(container: HTMLElement) {
    const results = await axe.run(container, {
        rules: { 'color-contrast': { enabled: false } },
    });
    const summary = results.violations.map(v => `${v.id}: ${v.help} (${v.nodes.length} nodes)`).join('\n');
    expect(results.violations, summary).toEqual([]);
}

function mockFetchJson(routes: Record<string, unknown>) {
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        const hit = Object.entries(routes).find(([path]) => url.includes(path));
        if (!hit) return new Response('{}', { status: 404 });
        return new Response(JSON.stringify(hit[1]), { status: 200, headers: { 'Content-Type': 'application/json' } });
    }));
}

beforeEach(() => {
    vi.unstubAllGlobals();
    // The renderer reads ?token= once and caches; a bare jsdom URL means no token — apiFetch
    // then sends no header, which is fine against the mocked fetch.
});

describe('a11y: RetryState', () => {
    it('renders an alert with an accessible Retry button, no axe violations', async () => {
        const { container } = render(
            <RetryState message="Couldn't load the model catalog" hint="Is the backend running?" onRetry={() => {}} />,
        );
        expect(screen.getByRole('alert')).toBeTruthy();
        expect(screen.getByRole('button', { name: 'Retry' })).toBeTruthy();
        await expectNoAxeViolations(container);
    });
});

describe('a11y: ModelManagerSection', () => {
    it('catalog list renders with labeled action buttons, no axe violations', async () => {
        mockFetchJson({
            '/api/models/catalog': {
                activeModelId: 'small-1b',
                catalog: [
                    { id: 'small-1b', label: 'Small 1B', ramGb: 1.5, sizeLabel: '0.8 GB download', paramsBillions: 1, quantization: 'Q4_K_M', isDownloaded: true, fileSizeBytes: 8e8 },
                    { id: 'big-8b', label: 'Big 8B', ramGb: 6.75, sizeLabel: '4.7 GB download', paramsBillions: 8, quantization: 'Q4_K_M', isDownloaded: false, fileSizeBytes: 0 },
                ],
            },
        });
        const { container } = render(<ModelManagerSection />);
        await waitFor(() => expect(screen.getByText('Small 1B')).toBeTruthy());
        expect(screen.getByRole('button', { name: /Download/ })).toBeTruthy();  // not-downloaded row
        expect(screen.getByRole('button', { name: /Delete/ })).toBeTruthy();    // downloaded (active) row
        expect(screen.getByText('Active')).toBeTruthy();                        // active badge on the pinned model
        await expectNoAxeViolations(container);
    });

    it('fetch failure renders the RetryState alert, no axe violations', async () => {
        vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('down'); }));
        const { container } = render(<ModelManagerSection />);
        await waitFor(() => expect(screen.getByRole('alert')).toBeTruthy());
        await expectNoAxeViolations(container);
    });
});

describe('a11y: NotesSection', () => {
    it('expander has aria-expanded and the opened list passes axe', async () => {
        mockFetchJson({
            '/api/notes': { notes: [{ filename: 'a.md', title: 'Note A', preview: 'body', modifiedAt: 1751500000000, sizeBytes: 2048 }] },
        });
        const { container } = render(<NotesSection />);
        const toggle = screen.getByRole('button', { name: /Saved Notes/ });
        expect(toggle.getAttribute('aria-expanded')).toBe('false');
        fireEvent.click(toggle);
        expect(toggle.getAttribute('aria-expanded')).toBe('true');
        await waitFor(() => expect(screen.getByText('Note A')).toBeTruthy());
        await expectNoAxeViolations(container);
    });
});

describe('a11y: MemorySection', () => {
    it('expander + clear-all affordance pass axe', async () => {
        mockFetchJson({
            '/api/memory/trajectories': { total: 1, trajectories: [{ goal: 'open settings', actionCount: 3, timestamp: '2026-07-01T00:00:00Z' }] },
        });
        const { container } = render(<MemorySection />);
        const toggle = screen.getByRole('button', { name: /Agent Memory/ });
        fireEvent.click(toggle);
        await waitFor(() => expect(screen.getByText('open settings')).toBeTruthy());
        expect(screen.getByRole('button', { name: /Clear All/ })).toBeTruthy();
        await expectNoAxeViolations(container);
    });
});
