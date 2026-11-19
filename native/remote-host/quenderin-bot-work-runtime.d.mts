import type { BotWorkScope } from './quenderin-bot-work-journal.mjs';
export interface BotWorkWriter { botRevision: string; prepare(sessionId: string, signal: AbortSignal): Promise<unknown>; prompt(request: { requestId: string; sessionId: string; mode: 'queue'; content: [{ type: 'text'; text: string }] }, signal: AbortSignal): Promise<unknown> }
export interface BotWorkAdapter { capability: string; botRevision: string; call(params: unknown, scope: BotWorkScope, signal?: AbortSignal): Promise<{ status: number; json: any }>; ready(): boolean; mounted(): boolean }
export function createBotWorkScope(hostDeviceId: string, peerDeviceId: string, peerIdentityKey: string, assertAuthorized: () => void): Readonly<BotWorkScope>;
export function mountBotWork(runtime: any, writer: BotWorkWriter, options?: { journal?: unknown; journalPath?: string }): BotWorkAdapter;
export function mountedBotWork(connection: unknown): BotWorkAdapter | undefined;
