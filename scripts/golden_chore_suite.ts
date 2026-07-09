/**
 * Golden chore suite — engineering reliability gate for the governed file agent.
 *
 * Runs fixed workspace chores against the real fs.* capabilities (no LLM):
 *   1. Organize by type (move pdfs/images into folders)
 *   2. Rename a file
 *   3. Write a report artifact
 *   4. Trash + undo round-trip
 *   5. verify() reports ok after a real move
 *
 * Exit 0 only if every check succeeds. Proves the tools are trustworthy without a model.
 *
 *   npx tsx scripts/golden_chore_suite.ts
 */
import fs from 'fs';
import os from 'os';
import path from 'path';
import {
    FsListCapability, FsMoveCapability, FsRenameCapability, FsWriteCapability, FsTrashCapability,
} from '../src/services/capability/fileCapabilities.js';

function mkWorkspace(): string {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'quenderin-golden-'));
    fs.writeFileSync(path.join(dir, 'notes.txt'), 'hello world');
    fs.writeFileSync(path.join(dir, 'report.pdf'), '%PDF-fake');
    fs.writeFileSync(path.join(dir, 'photo.jpg'), 'JPEG-fake');
    fs.writeFileSync(path.join(dir, 'todo.md'), '# todos');
    return dir;
}

async function main(): Promise<void> {
    const ws = mkWorkspace();
    const workspace = () => ws;
    let failed = 0;
    const check = async (name: string, fn: () => Promise<void>) => {
        try {
            await fn();
            console.log(`  ok   ${name}`);
        } catch (e) {
            failed++;
            console.log(`  FAIL ${name}: ${e instanceof Error ? e.message : String(e)}`);
        }
    };

    console.log('Golden chore suite');
    console.log(`workspace: ${ws}\n`);

    await check('organize: move report.pdf into Documents/ + verify', async () => {
        const cap = new FsMoveCapability(workspace);
        const out = await cap.run('report.pdf to Documents');
        if (!out.includes('Moved')) throw new Error(out);
        if (!fs.existsSync(path.join(ws, 'Documents', 'report.pdf'))) throw new Error('file not at dest');
        if (fs.existsSync(path.join(ws, 'report.pdf'))) throw new Error('source still present');
        const v = await cap.verify('report.pdf to Documents');
        if (!v.ok) throw new Error(v.detail);
    });

    await check('organize: move photo.jpg into Images/ + verify', async () => {
        const cap = new FsMoveCapability(workspace);
        const out = await cap.run('photo.jpg to Images');
        if (!out.includes('Moved')) throw new Error(out);
        const v = await cap.verify('photo.jpg to Images');
        if (!v.ok) throw new Error(v.detail);
    });

    await check('rename: notes.txt → notes-archive.txt + verify', async () => {
        const cap = new FsRenameCapability(workspace);
        const out = await cap.run('notes.txt to notes-archive.txt');
        if (!out.includes('Renamed')) throw new Error(out);
        if (!fs.existsSync(path.join(ws, 'notes-archive.txt'))) throw new Error('renamed file missing');
        const v = await cap.verify('notes.txt to notes-archive.txt');
        if (!v.ok) throw new Error(v.detail);
    });

    await check('write: create summary.md + verify', async () => {
        const cap = new FsWriteCapability(workspace);
        const out = await cap.run('summary.md | # Summary\n\nTwo files organized.');
        if (!out.includes('Created')) throw new Error(out);
        const body = fs.readFileSync(path.join(ws, 'summary.md'), 'utf8');
        if (!body.includes('Two files organized')) throw new Error('content mismatch');
        const v = await cap.verify('summary.md | # Summary\n\nTwo files organized.');
        if (!v.ok) throw new Error(v.detail);
    });

    await check('trash + undo: todo.md + verify', async () => {
        const cap = new FsTrashCapability(workspace);
        const trash = await cap.run('todo.md');
        if (!trash.includes('Trash')) throw new Error(trash);
        const v = await cap.verify('todo.md');
        if (!v.ok) throw new Error(v.detail);
        const restored = await cap.undo('todo.md');
        if (!/restored/i.test(restored)) throw new Error(restored);
        if (!fs.existsSync(path.join(ws, 'todo.md'))) throw new Error('undo did not restore');
        if (fs.existsSync(path.join(ws, 'Trash', 'todo.md'))) throw new Error('still in Trash after undo');
    });

    await check('list: workspace still readable', async () => {
        const out = await new FsListCapability(workspace).run();
        if (!out.includes('summary.md')) throw new Error(`list missing summary.md: ${out}`);
        if (!out.includes('notes-archive.txt')) throw new Error(`list missing renamed file: ${out}`);
    });

    await check('verify fails honestly on a phantom move', async () => {
        const cap = new FsMoveCapability(workspace);
        const v = await cap.verify('ghost.pdf to Nowhere');
        if (v.ok) throw new Error('expected verify to fail for missing move');
    });

    fs.rmSync(ws, { recursive: true, force: true });

    console.log();
    if (failed === 0) {
        console.log('ALL PASSED');
        process.exit(0);
    } else {
        console.log(`${failed} CHECK(S) FAILED`);
        process.exit(1);
    }
}

main().catch(e => {
    console.error(e);
    process.exit(1);
});
