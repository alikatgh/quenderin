export type BotReadDiagnosticCode = 'binding' | 'state' | 'request' | 'readiness' | 'revision' | 'workspace'
  | 'membership' | 'owners' | 'bot-fields' | 'projection' | 'state-changed' | 'ready';
export function mountBotRead(runtime: any): (params: unknown) => { status: number; json: unknown };
export function mountedBotRead(connection: unknown): { capability: string; botRevision: string; read: (params: unknown) => { status: number; json: unknown }; readDiagnostic: () => BotReadDiagnosticCode; mounted: () => boolean } | undefined;
export function botReadUnavailable(): { status: number; json: unknown };
export function botSessionWritable(connection: unknown, sessionId: unknown): boolean;
