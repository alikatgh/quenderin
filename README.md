# Quenderin

Quenderin is a proof-of-concept for **Offline, Autonomous Computer Usage**. Think of it as autonomous driving, but for your desktop and mobile OS.

The ultimate vision is for Quenderin to sit quietly, watching how you work and learning from your daily interactions. It operates as a voice-controlled assistant that takes over your tedious tasks—doing them faster and better, using local LLMs, screen parsing, and voice control to drive Android and Desktop interfaces autonomously.

**The Quenderin Paradox:**
This entire system infrastructure is explicitly and exclusively written by Google models. However, the agent itself runs **exclusively on local, offline models**, guaranteeing absolute data privacy and zero token costs for the end user.

---

## State of the Project: An Honest Audit

Short answer: it’s a *decent* prototype/POC idea but **quite brittle** and likely to fail in real-world, complex apps unless you add lots of engineering around it.

### Quick verdict
* **Good for:** rapid prototyping, simple screens, controlled emulators, research experiments, and exploring LLM-driven UI planning ideas.
* **Not great for:** robust automation, flaky UI flows, apps with custom views/graphics, production-level autonomous agents, or anything involving sensitive actions without strong safeguards.

### Why it’s brittle / major failure modes
1. **Coordinate brittle-ness:** Executing touches by raw coordinates breaks when screen sizes change or views move.
2. **Timing & race conditions:** Dumping hierarchy, deciding, and executing can be too slow relative to UI changes (animations, stale nodes).
3. **Lack of state verification:** If a TAP dismisses a dialog differently than expected, there's no robust way to detect divergence.
4. **Incomplete perception:** The backend discards "non-interactable" nodes, removing crucial context (visibility, labels).
5. **Custom rendering:** Many apps draw UI in canvases where view hierarchy is useless.
6. **LLM limitations:** Local LLMs are not deterministic enough for optimal low-level control loops over long periods.

### Implemented Architecture Improvements
Following this audit, the following robust features were immediately implemented into the agent's core OS Loop:
1. **View-Level Actions**: The Executor maps symbolic JSON `id` targets dynamically at runtime, avoiding stale coordinate clicks.
2. **Rich Perception State**: Non-interactable nodes are explicitly kept to provide the LLM with surrounding textual and layout context. Output is compressed into strict JSON.
3. **Event-driven idempotent primitives**: Fixed sleeps are gone. Replaced by `waitForUiIdle`, which actively polls the UI XML structure until animations settle.
4. **Separation of Concerns**: The LLM acts purely as a Symbolic Planner (`{"action": "click", "id": X}`), while a deterministic node backend handles the platform execution, bounds lookups, and retries.
5. **Safety Sandboxing**: A hardcoded keyword blocklist (e.g. "Pay", "Delete", "Password") prevents the LLM from interacting with potentially destructive or sensitive elements autonomously.

---

## How it Works

Quenderin interacts with interfaces using three main components:
1. **Perception**: Extracts the current screen context (e.g., via Android ADB view hierarchies).
2. **LLM Inference**: Feeds the context into a locally-running GGUF LLM (powered by `node-llama-cpp`), which plans the next action in a concise JSON format.
3. **Execution**: Translates the LLM's planned action into concrete UI inputs (e.g., adb shell input tap).

**Privacy & Offline-First:**
Quenderin runs **100% locally and offline**. It relies on an instruction-tuned LLaMA architecture (GGUF model) managed entirely on your local machine. There are no API keys required, no external network calls after initial model download, and zero telemetry.

---

## Setup and Usage

Installation and setup are fully integrated into the local Dashboard's React setup wizard, which will seamlessly guide you through downloading the required LLM weights and configuring voice control access.

### 1. Start the React Dashboard
The primary way to use Quenderin is through its interactive frontend dashboard.
```bash
npm install
npm run dashboard
```
Open your browser to `http://localhost:3000`. The Welcome Wizard will automatically start the setup process if this is your first time.

### 2. Run the Autonomous Agent Directly
If you want to run the agent backend standalone (for example, to execute a pre-determined task without the UI):
```bash
npm run agent
```

### 3. Desktop Application (Electron)
To run Quenderin as a standalone cross-platform desktop app:
```bash
npm run electron:dev
```
*(Or build the production macOS application with `npm run electron:build`)*

---

## Contributing
MIT License. PRs welcome!

---
**Stop configuring. Start automating.**
