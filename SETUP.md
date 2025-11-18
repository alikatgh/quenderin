# Quenderin Setup Guide

Get started with local LLM-powered code generation in minutes.

## Prerequisites

- Node.js 18 or higher
- 4-8GB of free RAM (depending on model size)
- 2-5GB of free disk space (for model files)

## Quick Start (5 minutes)

### 1. Install Dependencies

```bash
npm install
```

### 2. Build the Project

```bash
npm run build
```

### 3. Link the CLI Globally (Optional)

```bash
npm link
```

This makes the `quenderin` command available globally. Alternatively, use `npm start` or `node dist/index.js`.

### 4. Initialize Your Project

```bash
quenderin init
```

This creates:
- `models/` - Directory for LLM models
- `src/gen/` - Directory for generated code
- `prompts/` - Directory for prompt templates
- Updates `.gitignore` to exclude models and generated code

### 5. Download a Model

Choose one based on your available resources:

**Phi-3 Mini (Recommended for testing - ~2.3GB)**
```bash
curl -L -o models/phi-3-mini.Q4_K_M.gguf \
  https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf
```

**CodeLlama 7B (Best for code generation - ~3.8GB)**
```bash
curl -L -o models/codellama-7b.Q4_K_M.gguf \
  https://huggingface.co/TheBloke/CodeLlama-7B-Instruct-GGUF/resolve/main/codellama-7b-instruct.Q4_K_M.gguf
```

**Llama 3 8B (Most capable - ~4.7GB)**
```bash
curl -L -o models/llama-3-instruct-8b.Q4_K_M.gguf \
  https://huggingface.co/QuantFactory/Meta-Llama-3-8B-Instruct-GGUF/resolve/main/Meta-Llama-3-8B-Instruct.Q4_K_M.gguf
```

### 6. Verify Setup

```bash
quenderin model-info
```

You should see your downloaded model listed.

### 7. Generate Your First Code

```bash
quenderin add "Create a function that validates email addresses"
```

Or save to a file:

```bash
quenderin add "Create a function that validates email addresses" -o src/gen/validateEmail.ts
```

## Usage Examples

### Basic Code Generation

```bash
quenderin add "Create a TypeScript function to sort an array of objects by date"
```

### Save to Specific File

```bash
quenderin add "Create a user authentication middleware for Express" -o src/gen/auth.ts
```

### Control Output Length

```bash
quenderin add "Create a simple REST API client" -t 1500
```

The `-t` flag limits output to 1500 tokens.

## Configuration

Create a `quenderin.json` file in your project root to customize settings:

```json
{
  "modelPath": "models/codellama-7b.Q4_K_M.gguf",
  "maxTokens": 2048,
  "temperature": 0.1,
  "threads": 4,
  "outputDir": "src/gen"
}
```

See `quenderin.example.json` for a template.

## Available Commands

| Command | Description |
|---------|-------------|
| `quenderin init` | Initialize Quenderin in current project |
| `quenderin add "<prompt>"` | Generate code from a prompt |
| `quenderin model-info` | Show available models |
| `quenderin --help` | Show all commands and options |

## Troubleshooting

### "No models found"

Download a model using the curl commands above, or check the `models/` directory.

### "Out of memory" or slow generation

Try a smaller model like Phi-3 Mini, or reduce the number of threads:

```json
{
  "threads": 2
}
```

### Model loading takes too long

First load always takes 10-30 seconds. Subsequent generations use the cached model and are much faster.

### Generated code quality is poor

1. Use more specific prompts with examples
2. Try a larger/better model (CodeLlama for code, Llama 3 for general tasks)
3. Adjust temperature (lower = more deterministic, higher = more creative)

## Next Steps

- Check `examples/` directory for prompt templates
- Read `README.md` for the full vision and architecture
- Explore `models/README.md` for more model options

## Development

If you're contributing to Quenderin:

```bash
# Install dependencies
npm install

# Watch mode for development
npm run dev

# Build for production
npm run build

# Run without global install
npm start -- add "your prompt here"
```

## Architecture

```
quenderin/
├── src/
│   ├── index.ts        # CLI entry point
│   ├── generator.ts    # LLM integration
│   └── config.ts       # Configuration management
├── models/             # Local LLM models (gitignored)
├── examples/           # Example prompts
└── dist/               # Compiled output
```

## License

MIT - See LICENSE file for details.
