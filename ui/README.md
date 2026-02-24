# Quenderin Web UI

Super simple drag-and-drop interface for LLM connection setup.

## Features

- **Drag & Drop**: Drop your `quenderin.json` config file directly
- **Auto-detection**: Automatically detects local Ollama installation
- **Multiple Providers**: Support for Ollama, OpenAI, and OpenAI-compatible APIs
- **Live Testing**: Test your connection before saving
- **Beautiful UI**: Modern, gradient design with smooth animations

## Usage

Start the UI server:

```bash
quenderin ui
```

Then open your browser to: `http://localhost:3777`

You can specify a custom port:

```bash
quenderin ui --port 8080
```

## Setup Methods

### 1. Drag & Drop Config File
Simply drag and drop your `quenderin.json` file into the drop zone.

### 2. Quick Setup Form
Choose your provider and fill in the details:

- **Auto-detect**: Automatically finds and uses Ollama if available
- **Ollama**: Local LLM server (requires Ollama running)
- **OpenAI**: Official OpenAI API
- **OpenAI-Compatible**: Works with OpenRouter, Groq, LocalAI, etc.

### 3. Test Connection
Click "Test Connection" to verify your setup before saving.

## API Endpoints

The UI server exposes these endpoints:

- `GET /api/config` - Get current configuration
- `POST /api/config` - Save configuration
- `POST /api/upload-config` - Upload config file (multipart/form-data)
- `POST /api/test-connection` - Test LLM connection
- `GET /api/detect-ollama` - Auto-detect Ollama

## Technology

- Express.js server
- Vanilla JavaScript (no frameworks needed)
- Modern CSS with gradients and animations
- Drag & Drop API
- Fetch API for backend communication
