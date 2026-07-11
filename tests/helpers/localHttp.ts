import http from 'node:http';

/**
 * A pooling-free HTTP client for tests that spin up ephemeral `listen(0)` servers.
 *
 * Node's global `fetch` (undici) keeps connections alive and pools them per origin. Across a
 * parallel vitest run, many suites bind a random port, fire one request, and close the server
 * immediately — and the OS recycles those ephemeral port numbers. A pooled keep-alive connection
 * to a since-closed server on a now-reused port produced intermittent, load-dependent failures
 * (a response with headers reading `null`), which surfaced as flaky security-header assertions.
 *
 * `agent: false` gives each request its OWN one-shot agent — a brand-new socket that is closed
 * when the response ends and never returned to any pool. No reuse ⇒ no race, deterministic under
 * any amount of parallelism. Small surface on purpose: GET/POST with optional headers + JSON body.
 */
export interface LocalResponse {
    status: number;
    /** True for a 2xx status — mirrors `Response.ok`. */
    ok: boolean;
    headers: Record<string, string | string[] | undefined>;
    body: string;
    /** Case-insensitive single-value header read, mirroring `Response.headers.get`. */
    header(name: string): string | null;
    /** Parse the body as JSON (throws on invalid — tests want that to fail loudly). */
    json(): unknown;
}

function makeResponse(status: number, headers: LocalResponse['headers'], body: string): LocalResponse {
    return {
        status,
        ok: status >= 200 && status < 300,
        headers,
        body,
        header(name: string) {
            const v = headers[name.toLowerCase()];
            if (v === undefined) return null;
            return Array.isArray(v) ? v.join(', ') : v;
        },
        json() { return JSON.parse(body); },
    };
}

export function localRequest(
    url: string,
    opts: { method?: string; headers?: Record<string, string>; body?: string } = {},
): Promise<LocalResponse> {
    const method = opts.method ?? 'GET';
    const headers = { ...opts.headers };
    if (opts.body !== undefined && headers['Content-Type'] === undefined && headers['content-type'] === undefined) {
        headers['Content-Type'] = 'application/json';
    }
    return new Promise((resolve, reject) => {
        const req = http.request(url, { method, headers, agent: false }, (res) => {
            let body = '';
            res.setEncoding('utf8');
            res.on('data', (c) => { body += c; });
            res.on('end', () => resolve(makeResponse(res.statusCode ?? 0, res.headers, body)));
            res.on('error', reject);
        });
        req.on('error', reject);
        if (opts.body !== undefined) req.write(opts.body);
        req.end();
    });
}

export const localGet = (url: string, headers?: Record<string, string>) => localRequest(url, { headers });
export const localPost = (url: string, body: string, headers?: Record<string, string>) =>
    localRequest(url, { method: 'POST', body, headers });
