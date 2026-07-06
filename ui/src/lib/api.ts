/**
 * Per-launch auth token plumbing for the renderer (security audit HIGH #1). The local server now
 * requires this token on the WS upgrade AND on state-changing HTTP routes. Electron delivers it via
 * the preload (`window.quenderinAuth`); the CLI/browser path via the opened URL's `?token=`.
 */

/**
 * Q-525: pure helper — pull `token` out of a query string and rebuild the URL WITHOUT it, preserving
 * any other params + the hash. Kept DOM-free so it's unit-testable. `authToken()` uses it to strip the
 * token from the address bar (see below).
 */
export function extractAndStripToken(search: string, pathname: string, hash: string): { token: string; cleanUrl: string } {
    const params = new URLSearchParams(search);
    const token = params.get('token') ?? '';
    params.delete('token');
    const qs = params.toString();
    return { token, cleanUrl: pathname + (qs ? `?${qs}` : '') + hash };
}

// Captured ONCE at first use. `null` = not read yet; `''` = read, none present.
let cachedToken: string | null = null;

export function authToken(): string {
    if (cachedToken !== null) return cachedToken;
    // Electron: the preload delivers it out-of-band (never in the URL) — nothing to strip.
    const fromPreload = (window as { quenderinAuth?: { token?: string } }).quenderinAuth?.token;
    if (fromPreload) { cachedToken = fromPreload; return cachedToken; }
    // CLI/browser: it arrives in `?token=`. Read it once, then Q-525: strip it from the URL with
    // replaceState (no navigation/reload) so it doesn't linger in the address bar, browser history, or
    // a bookmark — a shoulder-surf + history-exfil vector. We keep the value cached for the session.
    const { token, cleanUrl } = extractAndStripToken(window.location.search, window.location.pathname, window.location.hash);
    if (token) {
        try { window.history.replaceState(null, '', cleanUrl); } catch { /* non-browser / restricted */ }
    }
    cachedToken = token;
    return cachedToken;
}

/**
 * Q-526: is a per-launch token available at all? When it isn't, apiFetch sends no auth header and every
 * protected route 401s with an opaque error — the app looks broken with no hint why. The renderer uses
 * this to show a "relaunch to reconnect" banner instead. A missing token is a real state: the Electron
 * preload always supplies one, but the CLI/browser path reads it from `?token=` which Q-525 STRIPS from
 * the URL after first read — so a plain page refresh (no cached token, no `?token=` left) lands here.
 */
export function hasAuthToken(): boolean {
    return authToken() !== '';
}

/**
 * `fetch` that attaches the auth token. Use it for EVERY state-changing call (POST/PUT/PATCH/DELETE)
 * AND for every GET to a user-data route — since Q-007/Q-274 the server also 401s un-tokened GETs to
 * `/api/sessions`, `/api/notes`, `/api/memory`, `/api/metrics`, `/diagnostics`. Plain `fetch` is only
 * safe for genuinely public probes (health/hardware). (Q-489: the old "GETs may use plain fetch" note
 * was stale and 401'd every Settings/Sidebar/Metrics panel.)
 */
export function apiFetch(input: string, init: RequestInit = {}): Promise<Response> {
    const headers = new Headers(init.headers);
    const token = authToken();
    if (token) headers.set('X-Auth-Token', token);
    return fetch(input, { ...init, headers });
}
