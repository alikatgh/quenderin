import type { BotWorkPayload, BotWorkReceipt } from './quenderin-bot-work-policy.mjs';
export interface BotWorkScope { hostDeviceId: string; peerDeviceId: string; peerKeySHA256: string; assertAuthorized(): void }
export interface BotWorkJournalEntry { version: 1; key: string; scope: Pick<BotWorkScope, 'hostDeviceId' | 'peerDeviceId' | 'peerKeySHA256'>; digest: string; requestId: string; receipt: BotWorkReceipt; pending: boolean }
export function botWorkPayloadDigest(payload: BotWorkPayload): string;
export function initializeBotWorkJournal(path: string, filesystem?: unknown): void;
export class BotWorkJournal {
 constructor(path: string, options?: { filesystem?: unknown });
 ready(): boolean;
 lookup(scope: BotWorkScope, payload: BotWorkPayload): BotWorkJournalEntry | undefined;
 reserve(scope: BotWorkScope, payload: BotWorkPayload): { kind: 'duplicate' | 'conflict' | 'reserved'; entry: BotWorkJournalEntry } | { kind: 'capacity' };
 transition(entry: BotWorkJournalEntry, receipt: BotWorkReceipt, pending: boolean): BotWorkJournalEntry;
}
