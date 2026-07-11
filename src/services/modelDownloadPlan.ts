/**
 * Pure decision logic for a resumable model download — extracted from `LlmService.downloadModel`
 * so the security-adjacent H9 case (byte-accounting on a resume) is unit-testable in isolation.
 *
 * Why this matters: the bytes this planning governs are fed to node-llama-cpp's GGUF parser, which
 * has memory-corruption→RCE CVEs. If a resume writes at the wrong offset, the on-disk file is
 * silently corrupt — and the resume path would keep appending to a poisoned partial. The three
 * outcomes below are the ONLY safe responses to what the server actually returned:
 *
 *  • 200 (server ignored our `Range:` — common with CDNs/redirects that answer the full body):
 *    the write stream must TRUNCATE and restart the byte counter from 0, or progress counts from
 *    the stale partial size and can exceed 100% (and the appended bytes would double the header).
 *  • 206 whose `Content-Range` start ≠ our partial size: appending would write at the wrong offset
 *    and corrupt the GGUF — DISCARD the partial and retry from scratch.
 *  • 206 whose `Content-Range` start == our partial size: the genuine happy resume — APPEND.
 *
 * This function is side-effect-free; the caller performs the fs unlink / stream-flag actions it
 * returns. Keep it in lockstep with the orchestration in `downloadModel`.
 */

export type DownloadWriteAction = 'restart' | 'resume' | 'discard';

export interface DownloadWritePlan {
    action: DownloadWriteAction;
    /** Byte offset the write stream starts at (0 for restart/discard-then-retry). */
    writeOffset: number;
    /** Open the write stream in append mode? True only for a verified resume. */
    append: boolean;
    /** Total expected size, for progress math. 0 when unknown (no Content-Length). */
    totalBytes: number;
    /** Present only when action === 'discard' — a human-readable reason for the thrown error. */
    discardReason?: string;
}

/** Parse the START byte of an HTTP `Content-Range: bytes <start>-<end>/<total>` header. */
export function parseContentRangeStart(header: string | null | undefined): number | null {
    if (!header) return null;
    const m = header.match(/bytes\s+(\d+)-/i);
    return m ? Number(m[1]) : null;
}

export function planDownloadWrite(input: {
    /** Size of the partial file already on disk (0 if none / fresh download). */
    partialBytes: number;
    /** HTTP status of the download response (200 full, 206 partial). */
    status: number;
    /** The response's `Content-Range` header, if any. */
    contentRange: string | null | undefined;
    /** The response's `Content-Length` (bytes in THIS response body). */
    contentLength: number;
}): DownloadWritePlan {
    const { partialBytes, status, contentRange, contentLength } = input;
    const isResume = status === 206;

    if (isResume) {
        const start = parseContentRangeStart(contentRange);
        if (start === null || start !== partialBytes) {
            return {
                action: 'discard',
                writeOffset: 0,
                append: false,
                totalBytes: 0,
                discardReason: `Download resume offset mismatch (server '${contentRange ?? 'none'}' vs local ${partialBytes}); discarded partial — please retry.`,
            };
        }
        // Genuine resume: the server is continuing exactly where our partial ended. If the 206
        // omits Content-Length we genuinely don't know the total — report 0 (unknown) so the caller's
        // `totalBytes > 0` progress guard skips, rather than dividing by partialBytes and emitting
        // >100% (bug hunt r-uc #19).
        return {
            action: 'resume',
            writeOffset: partialBytes,
            append: true,
            totalBytes: contentLength > 0 ? partialBytes + contentLength : 0,
        };
    }

    // 200 (or any non-206 success): the body is the WHOLE file. Ignore any partial, truncate.
    return {
        action: 'restart',
        writeOffset: 0,
        append: false,
        totalBytes: contentLength,
    };
}
