# Quenderin Documentation

Everything you need to understand, run, and extend Quenderin — the offline,
on-device AI agent.

## Start here

- **[ROADMAP.md](ROADMAP.md)** — the ONE consolidated roadmap: where the project
  is, the four horizons (ship → agent v1 → monetization → moat), the owner
  decision queue, and the permanent anti-goals. When plans disagree, this wins.
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — the whole system: the offline-first
  thesis, the desktop (Electron) app, the native-mobile destination, and the
  agent loop. Read this first.

## Reference

| Doc | What it covers |
|-----|----------------|
| [ROADMAP.md](ROADMAP.md) | **The consolidated roadmap** — current state, horizons 0–3, decision queue, anti-goals |
| [ARCHITECTURE.md](ARCHITECTURE.md) | System overview, data flow, the OODA agent loop, the two products |
| [BACKEND.md](BACKEND.md) | The `src/` services — LLM, agent, session, memory, voice, OCR, daemons, tools, device providers |
| [API.md](API.md) | The REST routes **and** the full WebSocket message protocol |
| [FRONTEND.md](FRONTEND.md) | The React/Vite UI — components, state, the agent socket hook, theming |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Setup, scripts, build, test, lint, project layout |
| [AGENT_AUTONOMY_PLAN.md](AGENT_AUTONOMY_PLAN.md) | **The plan for the mission** — local autonomous computer usage: the Shortcuts-shaped capability ladder, the consent/safety spine, and Milestone 0 (`fs.read`) |
| [ADDING_A_CAPABILITY.md](ADDING_A_CAPABILITY.md) | **Contributor guide** — how to add a governed capability: the tier model, the seam+fake pattern, safety rules, wiring, and tests |
| [ICON_EXTRACTION.md](ICON_EXTRACTION.md) | How the app icon is cut perfectly from the artwork — sharpness detection, the 5.8% inset math, per-platform derivation (written for future agent sessions) |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | How to contribute |

## The native mobile app

The iOS/Android rebuild has its own docs under `apple/`:

| Doc | What it covers |
|-----|----------------|
| [../apple/ARCHITECTURE.md](../apple/ARCHITECTURE.md) | What llama.cpp is, the **engine-vs-model** distinction, the native stack |
| [../apple/ROADMAP.md](../apple/ROADMAP.md) | Milestones M1–M4 and what's left |
| [../apple/QuenderinKit/README.md](../apple/QuenderinKit/README.md) | The Swift package module catalog |
| [../apple/QuenderinKit/INTEGRATION.md](../apple/QuenderinKit/INTEGRATION.md) | How to link llama.cpp on a device |

## One-paragraph summary

Quenderin runs large language models **fully on the user's device** — no cloud,
no API keys, no telemetry. The shipping prototype is an **Electron desktop app**
(TypeScript backend + React UI) that serves a dashboard, runs local GGUF models
via `node-llama-cpp`, and drives an agent loop that can observe a screen, plan a
symbolic action, execute it, and verify the result — all gated by a hard safety
blocklist. The **destination** is a native iOS/Android app (`apple/`) built on the
same llama.cpp engine. See [ARCHITECTURE.md](ARCHITECTURE.md) for the full picture.
