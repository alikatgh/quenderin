import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import axe from 'axe-core';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { VoiceInputButton } from '../src/components/VoiceInputButton.js';
import { VoiceModelStep } from '../src/components/onboarding/VoiceModelStep.js';
import { recommended, snapshot, speechFixture } from './speechFixtures.js';
import { setupMicrophone } from './microphoneFixture.js';

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

async function expectNoViolations(container: HTMLElement) {
    const { violations } = await axe.run(container, { rules: { 'color-contrast': { enabled: false } } });
    expect(violations, violations.map(item => item.id).join(', ')).toEqual([]);
}

describe('voice accessibility', () => {
    it('labels both model radios, filters, full table and progress', async () => {
        const speech = speechFixture();
        const { container } = render(<VoiceModelStep speech={{
            ...speech, downloads: { ...speech.downloads, snapshots: { [recommended]: snapshot('downloading') } },
        }} onFinish={vi.fn()} />);
        expect(screen.getByRole('group', { name: 'Choose a voice model' })).toBeTruthy();
        expect(screen.getAllByRole('radio')).toHaveLength(2);
        fireEvent.click(screen.getByRole('button', { name: 'Show all 29 models' }));
        expect(screen.getByRole('searchbox', { name: 'Search models' })).toBeTruthy();
        expect(screen.getByRole('checkbox', { name: 'Live preview' })).toBeTruthy();
        expect(screen.getByRole('checkbox', { name: 'Translates' })).toBeTruthy();
        expect(screen.getByRole('progressbar', { name: /Parakeet/ })).toBeTruthy();
        await expectNoViolations(container);
    });

    it('announces permission denial and keeps the named mic button keyboard reachable', async () => {
        const mic = setupMicrophone();
        try {
            mic.getUserMedia.mockRejectedValue(new DOMException('Denied', 'NotAllowedError'));
            const { container } = render(<VoiceInputButton transcribe={vi.fn()} onTranscript={vi.fn()} />);
            const control = screen.getByRole('button', { name: /Hold to talk.*Shift\+M/ });
            control.focus();
            fireEvent.keyDown(control, { key: ' ' });
            const alert = await screen.findByRole('alert');
            expect(alert.textContent).toMatch(/site permissions/);
            expect(control.getAttribute('aria-describedby')).toBe(alert.id);
            expect(document.activeElement).toBe(control);
            await expectNoViolations(container);
        } finally { cleanup(); mic.restore(); }
    });
});
