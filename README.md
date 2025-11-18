# Quenderin

**Generate code from plain English.** That's it.

## 💡 As Easy as Flipping a Light Switch

```bash
# Step 1: Install
npm install -g quenderin

# Step 2: Setup (interactive, takes 30 seconds)
quenderin setup

# Step 3: Generate code
quenderin add "Create a function to validate email addresses"
```

**Done.** You just generated production-ready code.

---

## 🚀 What You Get

- **Zero config** - Interactive setup finds the easiest option
- **Multiple LLM options** - Ollama (free), OpenAI (fast), or offline models
- **Clean code** - Production-ready with error handling
- **Your control** - Plain files you can edit and version control

## 📖 Examples

```bash
# Generate to stdout
quenderin add "Create a REST API endpoint for user registration"

# Save to file
quenderin add "Stripe checkout with error handling" -o src/checkout.ts

# Initialize project structure
quenderin init
```

---

## 🎯 Setup Options

The `quenderin setup` wizard guides you through the easiest path:

| Option | Time | Cost | When to Use |
|--------|------|------|-------------|
| **Ollama** | 2 min | Free | Local development, privacy |
| **OpenAI** | 30 sec | $$ | Production, best quality |
| **Compatible API** | 1 min | Varies | OpenRouter, Groq, LocalAI |

### Manual Setup (Optional)

Create `quenderin.json` in your project:

```json
{
  "provider": "openai",
  "apiKey": "sk-your-key",
  "modelName": "gpt-4o-mini"
}
```

---

## 🛠️ Commands

```bash
quenderin setup       # Interactive setup wizard
quenderin add "..."   # Generate code from prompt
quenderin init        # Initialize project structure
quenderin test        # Test LLM connection
```

---

## ⚡ Why Quenderin?

**Traditional coding:**
- Write boilerplate by hand
- Copy-paste from StackOverflow
- Spend hours on repetitive code

**With Quenderin:**
- Describe what you want in plain English
- Get clean, working code instantly
- Review and commit like a normal PR

---

## 📦 What Gets Installed?

- A CLI tool (`quenderin` command)
- Support for local and cloud LLMs
- No telemetry, no hidden APIs, no lock-in

---

## 🔒 Privacy & Control

- **Local-first**: Works completely offline with Ollama or GGUF models
- **No telemetry**: Zero tracking or data collection
- **Your code**: Plain files you own and control
- **Git-friendly**: Version control everything

---

## 📚 Advanced Usage

See our guides:
- [Simple Setup](SIMPLE-SETUP.md) - Detailed provider setup
- [Quickstart](QUICKSTART.md) - Complete walkthrough
- [Full Documentation](SETUP.md) - All features

---

## 🤝 Contributing

MIT License. Contributions welcome!

---

## 💬 Need Help?

```bash
quenderin --help
quenderin setup  # Re-run setup anytime
```

---

**That's it.** Install, setup, generate. As simple as turning on a light. 💡
