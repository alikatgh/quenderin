import { afterEach, describe, expect, it, vi } from 'vitest';
import { deflateSync } from 'node:zlib';
import { PNG } from 'pngjs';
import { validateImagePng } from '../src/utils/imagePng.js';

function chunk(type: string, data = Buffer.alloc(0)): Buffer {
    const encoded = Buffer.alloc(data.length + 12);
    encoded.writeUInt32BE(data.length, 0); encoded.write(type, 4, 4, 'ascii'); data.copy(encoded, 8);
    let crc = 0xffffffff;
    for (const byte of encoded.subarray(4, encoded.length - 4)) {
        crc ^= byte;
        for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
    encoded.writeUInt32BE((crc ^ 0xffffffff) >>> 0, encoded.length - 4);
    return encoded;
}
function png(colorType: 2 | 6 = 6): Buffer {
    const image = new PNG({ width: 2, height: 2 }); image.data.fill(128);
    return PNG.sync.write(image, { colorType });
}
function header(source: Buffer, edit: (data: Buffer) => void): Buffer {
    const data = Buffer.from(source.subarray(16, 29)); edit(data); return chunk('IHDR', data);
}
afterEach(() => vi.restoreAllMocks());

describe('bounded native PNG validation', () => {
    it.each([2, 6] as const)('accepts native 8-bit color type %s and validates checksums and pixels', color => {
        const decode = vi.spyOn(PNG.sync, 'read');
        expect(() => validateImagePng(png(color), 2, 2)).not.toThrow(); expect(decode).toHaveBeenCalledOnce();
    });
    it.each([64, 0xffffffff])('rejects a second IHDR claiming width %s before any decoder allocation', width => {
        const source = png();
        const malicious = Buffer.concat([source.subarray(0, 33), header(source, data => { data.writeUInt32BE(width, 0); data.writeUInt32BE(width, 4); }), source.subarray(33)]);
        const decode = vi.spyOn(PNG.sync, 'read').mockImplementation(() => { throw new Error('Decoder must not run.'); });
        expect(() => validateImagePng(malicious, 2, 2)).toThrow('structure'); expect(decode).not.toHaveBeenCalled();
    });
    it('rejects an interlaced compressed expansion before the unlimited inflate path', () => {
        const source = png();
        // A tiny header claims 2x2, while the compressed payload expands to 16 KiB.
        const malicious = Buffer.concat([source.subarray(0, 8), header(source, data => { data[12] = 1; }),
            chunk('IDAT', deflateSync(Buffer.alloc(64 * 64 * 4))), chunk('IEND')]);
        expect(malicious.length).toBeLessThan(200);
        const decode = vi.spyOn(PNG.sync, 'read').mockImplementation(() => { throw new Error('Decoder must not run.'); });
        expect(() => validateImagePng(malicious, 2, 2)).toThrow('structure'); expect(decode).not.toHaveBeenCalled();
    });
    it.each([['depth', 8, 16], ['grayscale', 9, 0], ['compression', 10, 1], ['filter', 11, 1]])('rejects unsupported %s before decoding', (_name, byte, value) => {
        const source = png(), decode = vi.spyOn(PNG.sync, 'read');
        const malicious = Buffer.concat([source.subarray(0, 8), header(source, data => { data[Number(byte)] = Number(value); }), source.subarray(33)]);
        expect(() => validateImagePng(malicious, 2, 2)).toThrow('structure'); expect(decode).not.toHaveBeenCalled();
    });
    it('bounds chunk lengths/count and rejects invalid order, missing data, bad IEND and trailing bytes', () => {
        const source = png(), oversized = Buffer.from(source); oversized.writeUInt32BE(0xffffffff, 8);
        const highBitType = Buffer.from(source); highBitType[12] |= 0x80;
        const first = source.subarray(0, 33), data = source.subarray(33, source.length - 12), end = chunk('IEND');
        const cases = [oversized, highBitType, source.subarray(0, source.length - 1), Buffer.concat([first, end]),
            Buffer.concat([first, data, chunk('IEND', Buffer.from([0]))]), Buffer.concat([source, Buffer.from([0])]),
            Buffer.concat([first, chunk('tEXt', Buffer.from('unexpected')), data, end]),
            Buffer.concat([source.subarray(0, 8), data, source.subarray(8, 33), end]),
            Buffer.concat([first, data, ...Array.from({ length: 4096 }, () => chunk('IDAT')), end])];
        const decode = vi.spyOn(PNG.sync, 'read');
        for (const bytes of cases) expect(() => validateImagePng(bytes, 2, 2)).toThrow('structure');
        expect(decode).not.toHaveBeenCalled();
    });
    it('permits consecutive bounded IDAT chunks but checks their CRC before accepting', () => {
        const source = png(), chunks: Buffer[] = [];
        let offset = 33;
        while (source.toString('ascii', offset + 4, offset + 8) === 'IDAT') {
            const length = source.readUInt32BE(offset); chunks.push(source.subarray(offset + 8, offset + 8 + length)); offset += length + 12;
        }
        const compressed = Buffer.concat(chunks), middle = Math.floor(compressed.length / 2);
        const split = Buffer.concat([source.subarray(0, 33), chunk('IDAT', compressed.subarray(0, middle)), chunk('IDAT', compressed.subarray(middle)), chunk('IEND')]);
        expect(() => validateImagePng(split, 2, 2)).not.toThrow();
        split[split.length - 1] ^= 1; expect(() => validateImagePng(split, 2, 2)).toThrow('checksums');
    });
    it('bounds the expected dimensions independently of untrusted headers', () => {
        const decode = vi.spyOn(PNG.sync, 'read');
        for (const dimension of [0, -1, 1.5, 1025, Number.MAX_SAFE_INTEGER]) expect(() => validateImagePng(png(), dimension, 2)).toThrow('structure');
        expect(decode).not.toHaveBeenCalled();
    });
});
