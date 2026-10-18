import { PNG } from 'pngjs';

const SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const MAX_BYTES = 8 * 1024 ** 2;
const MAX_DIMENSION = 1024;
const MAX_CHUNKS = 4096;

/**
 * Accept only the native stbi encoder's PNG subset before invoking the pixel decoder.
 * In particular, pngjs accepts repeated IHDRs and has an unbounded interlaced inflate
 * path. A byte cap and the first IHDR alone therefore do not bound its allocations.
 */
export function validateImagePng(bytes: Buffer, width: number, height: number): void {
    const invalid = () => { throw new Error('Runtime output PNG structure or dimensions are invalid.'); };
    if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1
        || width > MAX_DIMENSION || height > MAX_DIMENSION || bytes.length < 57 || bytes.length > MAX_BYTES
        || !bytes.subarray(0, 8).equals(SIGNATURE)) invalid();
    let offset = 8, count = 0, dataBytes = 0, ended = false;
    while (offset < bytes.length) {
        if (++count > MAX_CHUNKS || bytes.length - offset < 12) invalid();
        const length = bytes.readUInt32BE(offset);
        if (length > MAX_BYTES || length > bytes.length - offset - 12) invalid();
        const type = bytes.readUInt32BE(offset + 4);
        const next = offset + length + 12;
        if (count === 1) {
            if (type !== 0x49484452 || length !== 13) invalid(); // IHDR
            const header = offset + 8;
            if (bytes.readUInt32BE(header) !== width || bytes.readUInt32BE(header + 4) !== height
                || bytes[header + 8] !== 8 || (bytes[header + 9] !== 2 && bytes[header + 9] !== 6)
                || bytes[header + 10] !== 0 || bytes[header + 11] !== 0 || bytes[header + 12] !== 0) invalid();
        } else if (type === 0x49444154) { // IDAT
            dataBytes += length;
        } else if (type === 0x49454e44) { // IEND
            if (length !== 0 || dataBytes === 0 || next !== bytes.length) invalid();
            ended = true;
            break;
        } else invalid(); // Includes a second IHDR and all ancillary/unknown chunks.
        offset = next;
    }
    if (!ended) invalid();
    try {
        // The complete structure is now fixed to one bounded, noninterlaced 8-bit image.
        const decoded = PNG.sync.read(bytes, { checkCRC: true });
        if (decoded.width !== width || decoded.height !== height || decoded.data.length !== width * height * 4) throw new Error('Wrong pixels.');
    } catch { throw new Error('Runtime output PNG pixels or checksums are invalid.'); }
}
