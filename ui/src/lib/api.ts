/**
 * Per-launch auth token plumbing for the renderer (security audit HIGH #1). The local server now
 * requires this token on the WS upgrade AND on state-changing HTTP routes. Electron delivers it via
 * the preload (`window.quenderinAuth`); the CLI/browser path via the opened URL's `?token=`.
 */
export function authToken(): string {
    return (window as { quenderinAuth?: { token?: string } }).quenderinAuth?.token
        || new URLSearchParams(window.location.search).get('token')
        || '';
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
