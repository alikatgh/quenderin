export const APPROVAL_CAPABILITY: 'quenderin.approvals.v1';
export const APPROVAL_ENDPOINT: 'quenderin/approval';
export function assertPeerAllowed(deviceId: string, publicKey: string, path?: string): void;
export function actionDigest(request: unknown): string;
export class QuenderinApprovalPolicy {
  constructor(hostDeviceId: string, clientDeviceId: string, clock?: () => number, monotonic?: () => number);
  observe(endpoint: string, payload: unknown, value: unknown): unknown;
  consume(input: unknown): {args: {clientId: string; eventId: string; outcome: {kind: string; value: string}}};
  streamClosed(endpoint: string): void;
  close(): void;
}
