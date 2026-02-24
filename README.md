# Quenderin

Quenderin is the pursuit of **Autonomous Computer Usage**. Think of it as autonomous driving, but for your desktop and mobile OS. 

The ultimate vision is for Quenderin to sit quietly, watching how you work and learning from your daily interactions. It operates as a voice-controlled assistant that takes over your tedious tasks—doing them faster and better. When it makes a mistake, you correct it, and it learns from that correction instantly.

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

The tool opens a pull request with small, atomic commits, or directly drives your Android simulator depending on the invoked command.

Approve → merge → ship.

**If you don't:**
```
⚡ Quick setup - enter your OpenAI API key:
API Key: sk-your-key-here
✅ OpenAI configured! Using gpt-4o-mini
[Starts generating immediately]
```

**That's it.** One line. Then you're coding.

This tool is built to answer the hard questions of code generation and agentic UI automation.

| Promise | The Reality (How It Works) |
|---|---|
| **Deterministic Output** | The default LLM is a bundled 7B GGUF model, pinned to a specific SHA hash. Same schema + same prompt → identical output, forever. No drift. |
| **Manageable Reviews** | PRs are automatically split into small, logical commits, with a hard limit of \~300 lines per PR. No 3,000-line monoliths. |
| **Safe Manual Edits** | The "ejection problem" is solved via `quenderin freeze src/gen/checkout.ts`. This moves the file to `src/handwritten/`, rewrites all imports, and tells the generator to never touch it again. You are always in control. |
| **No Context Explosion** | The UI parser compresses Android view hierarchies into text coordinates. For generation, you guide context discovery with explicit `--include` and `--exclude` globs in your config. |
| **No Hidden Runtime** | Zero network calls after initial installation. Zero telemetry unless you explicitly opt-in. It runs on your machine, period. |

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
