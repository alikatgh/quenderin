// Dependency-free static server for website/ — exists because the sandboxed preview couldn't run
// the Xcode python http.server (PermissionError on getcwd), and the site needs no build step.
// Usage: node scripts/serve_website.mjs [port]   (default 8753)
import http from 'http';
import { promises as fs } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'website');
const port = Number(process.argv[2]) || 8753;
const MIME = {
    '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript',
    '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon',
    '.webmanifest': 'application/manifest+json', '.xml': 'application/xml', '.txt': 'text/plain',
    '.woff2': 'font/woff2', '.woff': 'font/woff',
};

http.createServer(async (req, res) => {
    try {
        const urlPath = decodeURIComponent(new URL(req.url, 'http://x').pathname);
        let rel = urlPath === '/' ? 'index.html' : urlPath.slice(1);
        const file = path.normalize(path.join(root, rel));
        if (!file.startsWith(root)) { res.writeHead(403).end(); return; }
        const data = await fs.readFile(file);
        res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] ?? 'application/octet-stream' });
        res.end(data);
    } catch {
        try {
            const nf = await fs.readFile(path.join(root, '404.html'));
            res.writeHead(404, { 'Content-Type': 'text/html' }).end(nf);
        } catch { res.writeHead(404).end('not found'); }
    }
}).listen(port, '127.0.0.1', () => console.log(`website/ at http://127.0.0.1:${port}`));
