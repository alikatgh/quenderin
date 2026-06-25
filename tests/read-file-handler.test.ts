import { describe, it, expect } from 'vitest';
import { executeTool } from '../src/services/tools/handlers.js';

const read = (p: string) => executeTool({ tool: 'read_file', args: { path: p } });

/**
 * read_file runs directly on untrusted model output (prompt injection), so $HOME containment is not
 * enough — credential stores live inside $HOME. These pin the sensitive-path denylist boundary that
 * the security audit (2026-06-23, HIGH) found untested. Pure path checks: no real secret files are
 * created or read (the denylist gate fires before the filesystem is touched).
 */
describe('read_file sensitive-path denylist (security audit HIGH)', () => {
    const sensitive = [
        '~/.ssh/id_rsa',
        '~/.ssh/config',
        '~/.aws/credentials',
        '~/.config/gcloud/credentials.db',
        '~/.config/gh/hosts.yml',
        '~/.netrc',
        '~/.env',
        '~/project/.env.local',
        '~/secrets.txt',
        '~/server.pem',
        '~/vault.keystore',
    ];
    it.each(sensitive)('denies %s as sensitive', async (p) => {
        const r = await read(p);
        expect(r.success).toBe(false);
        expect(r.error?.toLowerCase()).toContain('sensitive');
    });

    it('lets an ordinary path through the denylist to the existence check', async () => {
        const r = await read('~/this-file-almost-certainly-does-not-exist-9f3a2c.txt');
        expect(r.success).toBe(false);
        expect(r.error).toContain('File not found');
        expect(r.error?.toLowerCase()).not.toContain('sensitive');
    });

    it('still denies paths outside $HOME', async () => {
        const r = await read('/etc/passwd');
        expect(r.success).toBe(false);
        expect(r.error?.toLowerCase()).toContain('home directory');
    });

    it('rejects a missing path argument', async () => {
        const r = await read('');
        expect(r.success).toBe(false);
        expect(r.error?.toLowerCase()).toContain('missing path');
    });
});
