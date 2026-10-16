#!/usr/bin/env node
// The saved snapshot serves static previews and offline visitors. Production refreshes
// independently via the first-party Worker; it doesn't need a redeploy to find a release.
import { writeFile } from 'node:fs/promises';
import { discoverReleases } from '../workers/model-releases.mjs';
const data = await discoverReleases();
await writeFile(new URL('../website/data/model-releases.json', import.meta.url), JSON.stringify(data, null, 2) + '\n');
console.log('Saved ' + data.models.length + ' releases; checked ' + data.checkedAt);
