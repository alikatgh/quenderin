import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { GraniteSection } from './GraniteSection.js';
import type { VisionWorkflowAPI } from '../../../../src/electron/visionWorkflowTypes.js';
afterEach(cleanup);
it('uses the verified native model handle and retains a failed Granite draft across navigation', async () => {
    const answer = vi.fn(async () => { throw new Error('Synthetic model load failure'); });
    const api = { chooseGraniteModel: vi.fn(async () => ({ handle: 'opaque-native-selection', label: 'Converted model.gguf' })), answerGranite: answer, cancel: vi.fn(async () => {}) } as unknown as VisionWorkflowAPI;
    const view = render(<GraniteSection api={api} />);
    fireEvent.click(screen.getByRole('button', { name: 'Choose converted Granite model' })); await screen.findByText('Converted model.gguf');
    fireEvent.change(screen.getByLabelText('Message to Granite'), { target: { value: 'Keep my Granite question' } });
    fireEvent.click(screen.getByRole('button', { name: 'Ask Granite' })); await screen.findByRole('alert');
    expect(answer).toHaveBeenCalledWith({ modelHandle: 'opaque-native-selection', messages: [{ role: 'user', content: 'Keep my Granite question' }] });
    view.unmount(); render(<GraniteSection api={api} />);
    expect((screen.getByLabelText('Message to Granite') as HTMLTextAreaElement).value).toBe('Keep my Granite question');
    expect(screen.getByText('Converted model.gguf')).toBeDefined();
});
