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
 * — the server rejects un-tokened mutating requests with 401. Read-only GETs may use plain `fetch`.
 */
export function apiFetch(input: string, init: RequestInit = {}): Promise<Response> {
    const headers = new Headers(init.headers);
    const token = authToken();
    if (token) headers.set('X-Auth-Token', token);
    return fetch(input, { ...init, headers });
}
