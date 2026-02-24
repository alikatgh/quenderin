# Quenderin Quick Start

Get running in 3 commands:

## 1. Install & Build

```bash
npm install && npm run build
```

## 2. Download a Model

**Option A: Small & Fast (Phi-3 Mini - 2.3GB)**
```bash
curl -L -o models/phi-3-mini.Q4_K_M.gguf \
  https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf
```

**Option B: Code-Optimized (CodeLlama - 3.8GB)**
```bash
curl -L -o models/codellama-7b.Q4_K_M.gguf \
  https://huggingface.co/TheBloke/CodeLlama-7B-Instruct-GGUF/resolve/main/codellama-7b-instruct.Q4_K_M.gguf
```

## 3. Generate Code

```bash
node dist/index.js add "Create a TypeScript function to validate email addresses"
```

Or save to file:

```bash
node dist/index.js add "Create a user authentication middleware" -o src/gen/auth.ts
```

## That's it!

- See `SETUP.md` for detailed installation
- Check `examples/` for prompt templates
- Read `README.md` for the full vision

## All Commands

```bash
# Initialize project structure
node dist/index.js init

# Check available models
node dist/index.js model-info

# Generate code
node dist/index.js add "<your prompt here>"

# Generate with options
node dist/index.js add "<prompt>" -o output.ts -t 1500
```

## Link Globally (Optional)

```bash
npm link
# Now use: quenderin add "your prompt"
```
