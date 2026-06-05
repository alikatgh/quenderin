/**
 * Tests for the sanitizeAttachments function used in WebSocket input validation.
 * We test it indirectly by re-implementing the same logic since it's private to the module.
 */
import { describe, expect, it } from 'vitest';
import { MAX_ATTACHMENTS, MAX_ATTACHMENT_SIZE } from '../src/constants.js';

// Mirror the sanitization logic from websocket/index.ts for unit testing
function sanitizeAttachments(raw: unknown): { name: string; content: string }[] {
    if (!Array.isArray(raw)) return [];
    const result: { name: string; content: string }[] = [];
    for (const item of raw.slice(0, MAX_ATTACHMENTS)) {
        if (typeof item !== 'object' || item === null) continue;
        const name = typeof (item as any).name === 'string' ? (item as any).name.slice(0, 255) : '';
        const content = typeof (item as any).content === 'string' ? (item as any).content.slice(0, MAX_ATTACHMENT_SIZE) : '';
        if (name && content) {
            result.push({ name, content });
        }
    }
    return result;
}

describe('sanitizeAttachments', () => {
    it('returns empty array for non-array input', () => {
        expect(sanitizeAttachments(null)).toEqual([]);
        expect(sanitizeAttachments(undefined)).toEqual([]);
        expect(sanitizeAttachments('string')).toEqual([]);
        expect(sanitizeAttachments(42)).toEqual([]);
        expect(sanitizeAttachments({})).toEqual([]);
    });

    it('returns empty array for empty array', () => {
        expect(sanitizeAttachments([])).toEqual([]);
    });

    it('accepts valid attachments', () => {
        const result = sanitizeAttachments([
            { name: 'file.txt', content: 'hello world' },
        ]);
        expect(result).toEqual([{ name: 'file.txt', content: 'hello world' }]);
    });

    it('rejects items with missing name', () => {
        const result = sanitizeAttachments([
            { content: 'hello' },
        ]);
        expect(result).toEqual([]);
    });

    it('rejects items with missing content', () => {
        const result = sanitizeAttachments([
            { name: 'file.txt' },
        ]);
        expect(result).toEqual([]);
    });

    it('rejects non-object items', () => {
        const result = sanitizeAttachments([null, 'string', 42, true]);
        expect(result).toEqual([]);
    });

    it('truncates name to 255 characters', () => {
        const longName = 'a'.repeat(500);
        const result = sanitizeAttachments([
            { name: longName, content: 'data' },
        ]);
        expect(result[0].name.length).toBe(255);
    });

    it('truncates content to MAX_ATTACHMENT_SIZE', () => {
        const bigContent = 'x'.repeat(MAX_ATTACHMENT_SIZE + 1000);
        const result = sanitizeAttachments([
            { name: 'big.bin', content: bigContent },
        ]);
        expect(result[0].content.length).toBe(MAX_ATTACHMENT_SIZE);
    });

    it('limits to MAX_ATTACHMENTS items', () => {
        const many = Array.from({ length: MAX_ATTACHMENTS + 5 }, (_, i) => ({
            name: `file${i}.txt`,
            content: `content${i}`,
        }));
        const result = sanitizeAttachments(many);
        expect(result.length).toBe(MAX_ATTACHMENTS);
    });

    it('filters out invalid items while keeping valid ones', () => {
        const result = sanitizeAttachments([
            null,
            { name: 'good.txt', content: 'valid' },
            { name: '', content: 'no name' },
            { name: 'also-good.txt', content: 'also valid' },
            42,
        ]);
        expect(result).toEqual([
            { name: 'good.txt', content: 'valid' },
            { name: 'also-good.txt', content: 'also valid' },
        ]);
    });
});
