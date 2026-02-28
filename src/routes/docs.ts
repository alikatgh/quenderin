import { Router } from 'express';
import * as fs from 'fs/promises';
import * as path from 'path';
import { fileURLToPath } from 'url';

const router = Router();

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Ensure we compute the root of the quenderin project regardless of dist/ or src/ execution
// Non-compiled: __dirname = .../src/routes  → up 2 = project root
// Compiled:     __dirname = .../dist/src/routes → up 3 = project root
const isCompiledMode = __filename.includes('/dist/') || __filename.includes('\\dist\\');
const rootDir = isCompiledMode
    ? path.join(__dirname, '..', '..', '..')
    : path.join(__dirname, '..', '..');

router.get('/:filename', async (req, res) => {
    try {
        const { filename } = req.params;

        // 1. Strict Input Validation (Only allow .md files)
        if (!filename || !filename.toLowerCase().endsWith('.md')) {
            return res.status(400).json({ error: 'Only Markdown (.md) documents are supported.' });
        }

        // 2. Eradicate Path Traversal Vectors (strip all slashes/directories)
        const safeFilename = path.basename(filename);

        // 3. Dual-Path Resolution (Root -> /examples/)
        const rootPath = path.join(rootDir, safeFilename);
        const examplesPath = path.join(rootDir, 'examples', safeFilename);

        let fileContent = '';

        try {
            // Attempt root read first (e.g. README.md)
            fileContent = await fs.readFile(rootPath, 'utf-8');
        } catch {
            try {
                // Fallback to examples directory bounds
                fileContent = await fs.readFile(examplesPath, 'utf-8');
            } catch {
                return res.status(404).json({ error: `Document '${safeFilename}' not found in root or examples.` });
            }
        }

        res.type('text/plain');
        res.send(fileContent);

    } catch (err) {
        console.error('Failed to read markdown document:', err);
        res.status(500).json({ error: 'Internal server error while reading document.' });
    }
});

export default router;
