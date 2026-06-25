import { randomBytes, timingSafeEqual } from 'crypto';

/**
 * Per-launch session secret for the local server (security audit HIGH #1). The HTTP server + WS
 * endpoint bind 127.0.0.1 but have no authentication, so any co-resident local process (a malicious
 * npm postinstall, a second app, a browser extension's native host) could drive the autonomous
 * agent. Loopback binding is not an authorization boundary on a shared machine.
 *
 * The token is generated once at launch, handed ONLY to the trusted renderer (Electron: via the
 * preload `additionalArguments`; CLI browser: via the opened URL's `?token=`), and required on the
 * WS upgrade + state-changing HTTP routes. A local attacker that does `GET /` never receives it
 * (unlike a cookie / served-HTML token), so it actually authenticates the one trusted client.
 */
export function generateAuthToken(): string {
    return randomBytes(32).toString('hex');
}

/** Constant-time string equality (avoids leaking the token via compare timing). */
export function timingSafeEqualStr(a: string, b: string): boolean {
    const ab = Buffer.from(a, 'utf8');
    const bb = Buffer.from(b, 'utf8');
    if (ab.length !== bb.length) return false;   // length is not secret; unequal length can't match
    return timingSafeEqual(ab, bb);
}

/** Pull `?token=` out of a WS upgrade request URL (e.g. `/ws?token=abc`). Null when absent/malformed. */
export function extractWsToken(requestUrl: string | undefined): string | null {
    if (!requestUrl) return null;
    try {
        // requestUrl is path-relative ("/ws?token=…"); a base is required to parse it.
        const url = new URL(requestUrl, 'http://localhost');
        return url.searchParams.get('token');
    } catch {
        return null;
    }
}

/** True iff `provided` matches the launch token. Empty/absent expected token fails closed. */
export function isAuthorized(provided: string | null | undefined, expected: string): boolean {
    if (!expected || !provided) return false;
    return timingSafeEqualStr(provided, expected);
}
