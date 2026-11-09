/**
 * One live writer per conversation, adapted from Turnstone's workstream owner.
 *
 * A second writer does not append. The permit is the only release key. After
 * the lifetime passes, a new writer may take a crashed owner's place. Releasing
 * a stale permit does not clear the newer owner.
 */

export interface WriterPermit {
    conversationId: string;
    writerId: string;
    token: string;
    expiresAtMs: number;
}

export type WriterClaim =
    | { ok: true; permit: WriterPermit }
    | { ok: false; ownerId: string; message: string };

export function writerBusyMessage(ownerId: string): string {
    return `This conversation already has a live reply from "${ownerId}". Wait for it to finish.`;
}

export const WRITER_ID_MESSAGE = 'A conversation writer needs a conversation and a writer.';
export const WRITER_TTL_MESSAGE = 'A conversation writer needs a positive lifetime.';

export class ConversationWriter {
    private readonly owners = new Map<string, WriterPermit>();
    private nonce = 0;

    claim(conversationId: string, writerId: string, nowMs: number, ttlMs: number): WriterClaim {
        const conversation = conversationId.trim();
        const writer = writerId.trim();
        if (!conversation || !writer) return { ok: false, ownerId: '', message: WRITER_ID_MESSAGE };
        if (!Number.isFinite(nowMs) || !Number.isFinite(ttlMs) || ttlMs <= 0) {
            return { ok: false, ownerId: '', message: WRITER_TTL_MESSAGE };
        }
        const current = this.owners.get(conversation);
        if (current && nowMs < current.expiresAtMs) {
            return { ok: false, ownerId: current.writerId, message: writerBusyMessage(current.writerId) };
        }
        const permit: WriterPermit = {
            conversationId: conversation,
            writerId: writer,
            token: `${++this.nonce}`,
            expiresAtMs: nowMs + ttlMs,
        };
        this.owners.set(conversation, permit);
        return { ok: true, permit };
    }

    /** True only when this permit is still the live owner. */
    release(permit: WriterPermit, _nowMs: number): boolean {
        const current = this.owners.get(permit.conversationId);
        if (!current || current.token !== permit.token) return false;
        this.owners.delete(permit.conversationId);
        return true;
    }
}
