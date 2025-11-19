# Quenderin

**Just start talking. Get code.** That's it.

## 💡 Instant Start

```bash
# Install
npm install -g quenderin

# Start chatting and generating code
quenderin chat
```

**That's literally it.** On first run, it auto-detects your LLM or asks for an API key. Then you're immediately generating code.

---

## ⚡ Two Ways to Use

### 1️⃣ Chat Mode (Recommended)

```bash
quenderin chat
```

Just keep asking for code. No need to type the command over and over.

```
📝 What code do you want to generate?
> Create a function to validate email addresses

🤖 Generating...
[Your code appears here]

📝 What code do you want to generate?
> Now add password validation
...
```

### 2️⃣ One-off Generation

```bash
quenderin add "Create a REST API endpoint"
quenderin add "Stripe checkout" -o src/checkout.ts
```

---

## 🚀 First-Time Setup (Automatic)

The first time you run `quenderin chat` or `quenderin add`:

**If you have Ollama installed:**
```
✅ Auto-detected Ollama!
[Starts generating immediately]
```

**If you don't:**
```
⚡ Quick setup - enter your OpenAI API key:
API Key: sk-your-key-here
✅ OpenAI configured! Using gpt-4o-mini
[Starts generating immediately]
```

**That's it.** One line. Then you're coding.

---

## 🎯 What You Get

- **Zero friction** - Auto-setup on first run
- **Keep chatting** - Interactive mode for continuous generation
- **Smart defaults** - Auto-detects Ollama or uses gpt-4o-mini
- **Multiple LLMs** - Ollama (free), OpenAI (fast), or custom APIs
- **Your files** - Plain code you control and version

---

## 📖 Examples

```bash
# Start interactive mode (easiest)
quenderin chat

# Generate once
quenderin add "Create a function to parse CSV files"

# Save to file
quenderin add "User authentication middleware" -o src/auth.ts

# Re-run setup anytime
quenderin setup
```

---

## 🛠️ All Commands

```bash
quenderin chat         # Interactive chat mode
quenderin add "..."    # Generate code from prompt
quenderin setup        # Configure or reconfigure LLM
quenderin init         # Initialize project structure
quenderin test         # Test LLM connection
quenderin --help       # Show all options
```

---

## 🎯 LLM Options

First run tries **auto-detect**. If that doesn't work, you choose:

| Option | Setup | Cost | Best For |
|--------|-------|------|----------|
| **Ollama** | Auto-detected | Free | Privacy, offline use |
| **OpenAI** | API key | $$ | Speed, quality |
| **Custom API** | URL + key | Varies | OpenRouter, Groq, LocalAI |

---

## 💬 Philosophy

**Old way:**
1. Read documentation
2. Learn the tool
3. Configure everything
4. Finally start

**Quenderin:**
1. Type `quenderin chat`
2. Start talking
3. Get code

---

## 🔒 Privacy

- **Local-first**: Works offline with Ollama
- **No tracking**: Zero telemetry
- **Your code**: Plain files you own
- **Git-friendly**: Version control everything

---

## 💡 Why "Quenderin"?

Because turning on the light should be this simple:

```bash
quenderin chat
> Create a function to validate emails
[Code appears]
```

**Just. That. Simple.**

---

## 📚 Advanced

For power users who want full control:

- [Detailed Setup Guide](SIMPLE-SETUP.md)
- [Project Configuration](QUICKSTART.md)
- [All Features](SETUP.md)

---

## 🤝 Contributing

MIT License. PRs welcome!

---

**Stop configuring. Start coding.** ⚡
