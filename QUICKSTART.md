# Quickstart

Get Quenderin running in 5 minutes or less.

## What is Quenderin?

Quenderin is an **offline, privacy-first AI assistant** that runs entirely on your local hardware — no API keys, no cloud, no telemetry. It combines a local LLM (Llama 3 / 3.2 in GGUF format) with a React dashboard, voice control, screen parsing, and Android device automation.

Everything communicates over a local WebSocket connection. Your data never leaves your machine.

---

## Step 1 — Install dependencies

Run from the project root:

```bash
npm install
cd ui && npm install && cd ..
```

**What this installs:**
- **Backend:** Express, `node-llama-cpp`, `ws`, voice/OCR services
- **Frontend:** React 18, Vite, Tailwind CSS, `lucide-react`, ReactMarkdown (inside `ui/`)

> **Requirements:** Node.js 20 or higher, npm 9+. No Python or native builds required — `node-llama-cpp` ships prebuilt binaries for macOS (arm64/x86), Linux, and Windows.

---

## Step 2 — Build the UI bundle (first time only)

```bash
cd ui && npm run build && cd ..
```

This compiles the React app into `public/` where the Express server serves it. You only need to rebuild when you change UI source code.

---

## Step 3 — Start the dashboard

```bash
npm run dashboard
```

Expected terminal output on successful start:

```
[Server] Starting Quenderin dashboard...
[Server] Dashboard running at http://localhost:3000
[WebSocket] WebSocket server ready
```

If port `3000` is already occupied by another process, Quenderin automatically finds the next free port:

```
[Server] Port 3000 is busy, starting on port 3001 instead.
[Server] Dashboard running at http://localhost:3001
```

Open the URL shown in your terminal in any browser.

---

## Step 4 — Download a model (first run only)

The **Welcome Wizard** or **Models** tab will prompt you to download a model. Models are stored in `~/.quenderin/models/` on your system.

Choose a model based on your available RAM:

| Model | RAM needed | Best for |
|-------|------------|----------|
| Llama 3.2 1B | ~2 GB | Very low-RAM machines, fastest responses |
| Llama 3.2 3B | ~4 GB | Everyday tasks, balanced speed and quality |
| Llama 3 8B | ~8–10 GB | Best quality, code, reasoning |

Quenderin **auto-selects** the best downloaded model that safely fits in memory. Downloads support **resume** — if interrupted, restarting picks up from where it left off using HTTP range requests and persisted metadata.

> **Tip:** You can install multiple models. Quenderin always picks the smartest one that fits.

---

## Step 5 — Start chatting

Open the **General Chat** tab. Every assistant reply shows live generation stats below the message:

```
⚡ 42 tok/s   •   317 tokens   •   TTFT 0.8s   •   7.5s total
```

| Metric | Meaning |
|--------|---------|
| **tok/s** | Generation speed (tokens per second). Higher = faster hardware or smaller model |
| **tokens** | Number of tokens in this response |
| **TTFT** | Time-to-first-token — how long before the model started writing |
| **total** | Full wall-clock generation time |

---

## Step 6 — Try a preset

Use the pill buttons below the chat input to switch between five built-in **persona presets**:

| Preset | Best for | Temperature |
|--------|----------|-------------|
| General Assistant | All-purpose Q&A | 0.7 |
| Code Review | Identifying bugs and improvements | 0.3 |
| Creative Writer | Stories, emails, blog posts | 0.9 |
| Tutor | Step-by-step explanations | 0.5 |
| Summarizer | Condensing long content | 0.3 |

Switching a preset instantly changes the system prompt and generation parameters. The chat session resets so the new persona takes effect immediately — no stale context bleed-through.

---

## Step 7 — Adjust settings

Open the **Settings** tab to configure:

| Setting | What it does |
|---------|--------------|
| Context size | Max tokens kept in memory (512 – 8192). Higher = more memory, smarter context |
| Memory safety | Blocks loading models that won't safely fit in RAM |
| Theme | Light, Dark, or System |
| Privacy lock | Locks the UI behind a PIN after an idle period |

Use **Reset Defaults** at any time to restore all settings to safe values (context 2048, memory safety on, theme system).

---

## Quick troubleshooting

| Problem | Solution |
|---------|----------|
| Dashboard won't open | Check terminal — port may have changed (e.g. `:3001`) |
| No model available | Go to Models tab and download one |
| Download stopped mid-way | Re-trigger it — it resumes automatically |
| Slow responses | Try a smaller model or lower the context size |
| No voice features | Set `PICOVOICE_ACCESS_KEY` environment variable before starting |

For detailed diagnostics, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## Other run modes

```bash
# Run the agent backend only (no browser UI)
npm run agent

# Run as a native desktop app (Electron)
npm run electron:dev

# Build a production macOS .dmg
npm run electron:build
```
