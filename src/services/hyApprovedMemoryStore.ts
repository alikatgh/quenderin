import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { parseHyMemoryProposals, type HyMemoryNotePort } from './hyMemory.js';
import { WindowsPrivateMemoryAcl, type PrivateMemoryAclPort } from './windowsPrivateMemoryAcl.js';

/** Explicitly approved personal facts are private app data, separate from legacy notes. */
export class HyApprovedMemoryStore implements HyMemoryNotePort {
    private tail: Promise<unknown> = Promise.resolve();
    constructor(readonly directory = path.join(os.homedir(), '.quenderin', 'approved-memories'), private readonly platform: NodeJS.Platform = process.platform, private readonly acl: PrivateMemoryAclPort = new WindowsPrivateMemoryAcl()) {}
    get unavailableReason(): string | null { return null; }

    saveNote(title: string, content: string): Promise<{ path: string } | { error: string }> {
        if (this.unavailableReason) return Promise.resolve({ error: this.unavailableReason });
        const operation = this.tail.then(() => this.save(title, content), () => this.save(title, content));
        this.tail = operation.catch(() => undefined);
        return operation.catch(() => ({ error: 'Could not save the selected approved memory in private app storage. Existing records were preserved.' }));
    }
    private async savedRecord(file: string, expected: string): Promise<boolean> {
        let handle: fs.promises.FileHandle;
        try { handle = await fs.promises.open(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW); }
        catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false; throw error; }
        try {
            const before = await handle.stat();
            if (!before.isFile() || before.size > 4096 || (this.platform !== 'win32' && (before.mode & 0o077) !== 0)) throw new Error('Unsafe approved-memory record.');
            if (this.platform === 'win32') { await this.acl.verifyFile(file); const entry = await fs.promises.lstat(file); if (entry.isSymbolicLink() || entry.dev !== before.dev || entry.ino !== before.ino) throw new Error('Private file identity changed.'); }
            const data = Buffer.alloc(4097), { bytesRead } = await handle.read(data, 0, data.length, 0), after = await handle.stat();
            if (bytesRead > 4096 || before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs || data.subarray(0, bytesRead).toString('utf8') !== expected) throw new Error('Approved-memory record differs.');
            return true;
        } finally { await handle.close(); }
    }
    private async save(title: string, content: string): Promise<{ path: string }> {
        const match = /^Hy memory ([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/i.exec(title);
        if (!match || typeof content !== 'string') throw new Error('Invalid approval.');
        parseHyMemoryProposals(JSON.stringify({ memories: [content] }));
        const id = match[1].toLowerCase(), encoded = JSON.stringify({ id, text: content });
        if (this.platform === 'win32') await this.acl.ensureDirectory(this.directory);
        else await fs.promises.mkdir(this.directory, { recursive: true, mode: 0o700 });
        const directory = await fs.promises.lstat(this.directory);
        if (!directory.isDirectory() || directory.isSymbolicLink() || (this.platform !== 'win32' && (directory.mode & 0o077) !== 0)) throw new Error('Approved memories require a private directory.');
        const final = path.join(this.directory, `${id}.json`);
        if (await this.savedRecord(final, encoded)) return { path: final };
        let count = 0;
        for await (const _entry of await fs.promises.opendir(this.directory)) { if (++count >= 1000) throw new Error('Approved-memory capacity reached.'); }
        const staging = path.join(this.directory, `.${crypto.randomUUID()}.partial`);
        try {
            const handle = await fs.promises.open(staging, 'wx', 0o600);
            try {
                if (this.platform === 'win32') {
                    const before = await handle.stat(); await this.acl.verifyFile(staging);
                    const entry = await fs.promises.lstat(staging), after = await fs.promises.lstat(this.directory);
                    if (entry.isSymbolicLink() || entry.dev !== before.dev || entry.ino !== before.ino || directory.dev !== after.dev || directory.ino !== after.ino) throw new Error('Private storage identity changed.');
                }
                await handle.writeFile(encoded, 'utf8'); await handle.sync();
            } finally { await handle.close(); }
            try { await fs.promises.link(staging, final); }
            catch (error) { if ((error as NodeJS.ErrnoException).code !== 'EEXIST' || !await this.savedRecord(final, encoded)) throw error; }
            if (this.platform === 'win32') await this.acl.verifyFile(final);
            return { path: final };
        } finally { await fs.promises.unlink(staging).catch(() => undefined); }
    }
}
