# Quenderin Build & Run Guide

To run the Quenderin Agent and its User Interface locally, you generally need to start both the backend daemon and the frontend server during development.

## 1. Running the Backend Daemon (Root Folder)

The root folder contains the core LLM execution engine, spatial UI processing, and the Android ADB bridges.

Open a terminal in the root project folder directory (`/Users/s_avelova/Documents/projects/quenderin`) and run the following command:

```bash
# Start the backend dashboard server and WebSocket daemon
npm run dashboard
```
*This starts the daemon (typically on `localhost:3000`). The frontend relies on this backend being active to process Android commands.*

**Other available root commands:**
- `npm run electron:dev`: Builds TypeScript and launches the desktop Electron app wrapper in development mode.
- `npm run electron:build`: Compiles and builds the production `.dmg` or Mac bundle.
- `npm run agent "<goal>"`: Runs the agent in a headless Command Line mode.

---

## 2. Running the Frontend UI (ui Folder)

The `ui` folder contains the React + Vite frontend dashboard.

Open a **new** separate terminal tab, navigate to the `ui` folder (`/Users/s_avelova/Documents/projects/quenderin/ui`), and run:

```bash
# Start the Vite development frontend
npm run dev
```

*This will start the Vite server (typically on `localhost:5173`). Once loaded in your browser, it will automatically attempt to connect to the backend daemon's WebSocket.*

---

## Pre-Requisites & Troubleshooting

1. **Install Dependencies**: Ensure you've run `npm install` in **both** the root folder and the `ui` folder before starting.
2. **Android Simulator**: Make sure your Android Emulator is actively running (or a physical Android device is plugged in with USB Debugging enabled) before starting the Agent commands so it can extract the UI spatial data.
3. **LLM Requirements**: The backend relies on an offline LLaMA 3 check-point and requires sufficient RAM to load the model into memory.
