# Troubleshooting

Diagnostic guide for common problems. Work through each section top-to-bottom before asking for help.

---

## Dashboard won't start

### Symptom A — port conflict

```
Error: listen EADDRINUSE: address already in use :::3000
```

**What happened:** Another process is running on port 3000. Quenderin auto-detects this and should switch to the next free port automatically. If the error still appears, your version may not have the port-fallback fix.

**Solution:**

1. Check whether Quenderin found another port — look for this message:
   ```
   [Server] Port 3000 is busy, starting on port 3001 instead.
   ```
   If yes, open whichever URL is printed. No further action needed.

2. If it crashed without finding another port, manually free port 3000:
   ```bash
   lsof -ti:3000 | xargs kill
   npm run dashboard
   ```

3. Or specify a custom port:
   ```bash
   PORT=3001 npm run dashboard
   ```

### Symptom B — crash immediately on startup with no error message

Check that your Node.js version is 20 or higher:

```bash
node --version
```

If below 20, upgrade via `nvm` or `brew`:

```bash
# Using nvm
nvm install 22 && nvm use 22

# Using Homebrew
brew install node@22
```

### Symptom C — `Cannot find module` or `ERR_MODULE_NOT_FOUND`

Dependencies may not be installed:

```bash
npm install
cd ui && npm install && cd ..
```

Then restart.

---

## No model available / AI responses don't work

### Symptom

Chat area shows "No model loaded" or messages time out with no response.

### Diagnosis

1. Look for model files:
   ```bash
   ls ~/.quenderin/models/
   ```
   If the directory is empty or doesn't exist, no model is installed.

2. Check the terminal for load errors such as:
   ```
   [LLM] No suitable model found
   [LLM] Memory check failed for llama-3-8b
   ```

### Solutions

- **No model files:** Open the Models tab and download a model. Start with Llama 3.2 3B if unsure.
- **Memory check failed:** You have a model installed but not enough free RAM. Either:
  - Download a smaller model (3B or 1B)
  - Disable memory safety in Settings and try loading anyway
  - Close other memory-heavy apps before starting Quenderin

### Model directory location

Models are stored at `~/.quenderin/models/` by default. You can override this by setting `modelPath` in `quenderin.json`.

---

## Model download stopped mid-way

### What happened

Network interruption, system sleep, or manual stop during download.

### Solution

Re-trigger the same model download from the Models tab. Quenderin automatically detects the partial file and the `.download.json` sidecar metadata, then resumes from the last saved byte position using HTTP range requests.

**You do not need to delete the partial file.** Deleting it forces a full restart.

### If the download won't resume

If the partial file appears corrupted (download fails immediately after starting):

```bash
rm ~/.quenderin/models/<model-id>.gguf
rm ~/.quenderin/models/<model-id>.download.json
```

Then re-download from scratch.

---

## Responses are very slow

### Expected performance

| Hardware | Model | Expected tok/s |
|----------|-------|----------------|
| Apple M2 (8 GB) | Llama 3.2 1B | 60–100 tok/s |
| Apple M2 (8 GB) | Llama 3.2 3B | 25–50 tok/s |
| Apple M2 (16 GB) | Llama 3 8B | 20–35 tok/s |
| Intel i7 (RAM only) | Llama 3.2 3B | 5–15 tok/s |

If you're seeing significantly lower numbers:

1. **Switch to a smaller model.** Try 3B → 1B.
2. **Lower context size** in Settings (4096 → 2048 → 1024). Smaller context = faster prompt evaluation.
3. **Check memory pressure.** If the system is swapping (purple bar in Activity Monitor), the model is being read from disk during generation — extremely slow. Free up RAM.
4. **Check thread count.** If you set `threads` in `quenderin.json`, try removing it to let `node-llama-cpp` pick automatically.

The generation stats bar under each message shows `tok/s` and `TTFT` — use these to benchmark changes.

---

## Voice / wake-word features don't work

### Symptom

```
[Voice] PICOVOICE_ACCESS_KEY not set — voice features disabled
```

Or the voice control button is greyed out in the UI.

### Solution

1. Get a free access key from [Picovoice Console](https://console.picovoice.ai/)
2. Set the key before starting the dashboard:
   ```bash
   export PICOVOICE_ACCESS_KEY="your-key-here"
   npm run dashboard
   ```
3. To persist it, add it to your shell profile (`~/.zshrc` or `~/.bash_profile`).

Voice features are entirely optional. All other features work without this key.

---

## Settings seem wrong or stuck

### Symptom

Saved settings don't apply, or the app behaves as if using different values.

### Solution

Use **Reset Defaults** in the Settings tab. This restores all values to:

| Setting | Default |
|---------|---------|
| Context size | 2048 |
| Memory safety | Enabled |
| Theme | System |
| Privacy lock | Disabled |

After reset, re-apply only the settings you actually want to change.

### If settings reset doesn't help

The settings may be invalid values rejected by the backend. Open browser DevTools → Network → WebSocket and look for `settings_update` messages to see what values are being sent and whether the backend acknowledges them.

---

## Privacy lock — locked out

### Symptom

You set a privacy lock PIN and can't remember it.

### Solution

Settings are stored client-side. To reset:

1. Open browser DevTools (F12)
2. Go to Application → Local Storage → `http://localhost:3000`
3. Delete the key related to privacy lock / PIN
4. Refresh the page

Alternatively, try **Reset Defaults** from the Settings tab if you can still access it.

---

## TypeScript errors in development

### Check both projects

```bash
# Backend
npx tsc --noEmit

# Frontend
cd ui && npx tsc --noEmit
```

### Common errors and fixes

| Error | Likely cause | Fix |
|-------|-------------|-----|
| `Property X does not exist on type Y` | Missing interface field | Add the field to the relevant type in `src/types/index.ts` or `ui/src/types/index.ts` |
| `Cannot find module` | Import path wrong or missing file | Check relative path and file extension (`.js` required in ESM imports) |
| `Type 'string' is not assignable to type '"light" \| "dark" \| "system"'` | Value not narrowed to literal union | Use `as const` or explicit type annotation |
| `ui/tsconfig.tsbuildinfo` conflicts | Build artifact out of sync | Run `cd ui && rm -f tsconfig.tsbuildinfo && npx tsc --noEmit` |

Do not edit `ui/tsconfig.tsbuildinfo` directly — it is a generated build cache.

---

## In-app docs show "Page Not Found" or blank

### Cause

The docs route (`GET /api/docs/:filename`) only serves `.md` files that physically exist in the project root directory (or `examples/` subdirectory). A missing file results in a 404.

### Expected files

The following must exist in the project root:

```
README.md
QUICKSTART.md
SETUP.md
FEATURES.md
TROUBLESHOOTING.md
SECURITY.md
RUN_GUIDE.md
```

### Fix

If a file is missing, restore it from git:

```bash
git checkout HEAD -- QUICKSTART.md
```

Or re-create it by running the documentation generator.

---

## WebSocket connection drops or never connects

### Symptom

Chat input is disabled, connection spinner stays active, or browser console shows `WebSocket connection failed`.

### Diagnosis

1. Confirm the dashboard is still running (check your terminal — it may have crashed).
2. Confirm the URL in your browser matches the port printed by the dashboard.
3. Open browser DevTools → Console and look for WebSocket error messages.

### Solutions

- Restart the dashboard: `npm run dashboard`
- Hard-refresh the browser (`Cmd+Shift+R` or `Ctrl+Shift+R`)
- Check if another process killed the Node.js process (common if running background tasks or sleep/wake)
- Try a different browser to rule out extension interference

---

## Getting more debug output

Start the dashboard with verbose logging:

```bash
LOG_LEVEL=debug npm run dashboard
```

The logger (`src/utils/logger.ts`) will emit `[DEBUG]` prefixed messages from all services, including model lifecycle, intent classification, tool loop iterations, and WebSocket message routing.
