# Super Simple Setup ⚡

Get code generation running in **under 2 minutes**!

## Step 1: Install

```bash
npm install
npm run build
```

## Step 2: Run Setup

```bash
node dist/index.js setup
```

That's it! The setup will:
- ✨ Auto-detect if you have Ollama installed
- 🎯 Guide you to the easiest option for your system
- ⚡ Get you generating code in seconds

## Three Easy Options

### Option 1: Ollama (EASIEST - No API keys!)

```bash
# 1. Install Ollama from https://ollama.ai
# 2. Pull a model:
ollama pull codellama

# 3. Done! Start generating:
node dist/index.js add "Create a function to validate emails"
```

### Option 2: OpenAI API (1 minute)

Create `quenderin.json`:
```json
{
  "provider": "openai",
  "apiKey": "sk-your-api-key",
  "modelName": "gpt-4"
}
```

Done! Now run:
```bash
node dist/index.js add "Create a user authentication function"
```

### Option 3: Any OpenAI-Compatible API

Works with: OpenRouter, LocalAI, LM Studio, Groq, etc.

Create `quenderin.json`:
```json
{
  "provider": "openai",
  "apiKey": "your-key",
  "baseURL": "https://your-api-endpoint",
  "modelName": "your-model"
}
```

## Usage Examples

```bash
# Generate and display code
node dist/index.js add "Create a TypeScript function to sort users by date"

# Save to file
node dist/index.js add "Create auth middleware" -o src/gen/auth.ts

# Test connection
node dist/index.js test
```

## Why This is Simple

✅ **No model downloads** if using Ollama or cloud APIs
✅ **Auto-detection** finds the best available option
✅ **Clear instructions** for each setup method
✅ **Works immediately** after minimal config
✅ **Multiple options** - choose what works for you

## Comparison

| Method | Setup Time | Cost | Best For |
|--------|-----------|------|----------|
| **Ollama** | 2 min | Free | Most users (local, fast) |
| **OpenAI** | 1 min | Pay per use | Production, best quality |
| **OpenRouter** | 1 min | Pay per use | Access to many models |
| **GGUF Models** | 15+ min | Free | Offline, full control |

## Need Help?

```bash
# See all commands
node dist/index.js --help

# Test if setup worked
node dist/index.js test

# Re-run setup
node dist/index.js setup
```

## Full Documentation

For advanced usage, see:
- `README.md` - Full project vision
- `SETUP.md` - Detailed installation
- `examples/` - Prompt templates
