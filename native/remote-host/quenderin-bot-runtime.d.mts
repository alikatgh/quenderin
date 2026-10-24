export function mountBotRead(runtime: any): (params: unknown) => { status: number; json: unknown };
export function mountedBotRead(connection: unknown): { capability: string; botRevision: string; read: (params: unknown) => { status: number; json: unknown }; mounted: () => boolean } | undefined;
export function botReadUnavailable(): { status: number; json: unknown };
export function botSessionWritable(connection: unknown, sessionId: unknown): boolean;
