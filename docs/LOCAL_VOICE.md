# Local voice on desktop

Quenderin’s desktop setup lets you add an optional speech model for dictation.
The speech model turns your words into text. The local chat model you choose
answers the message when you send it.

This guide describes the unreleased desktop source integration. Verification with
a real microphone and full speech model weights is pending.

## Set up voice

1. Choose the local model you want to talk to in step 1. You can continue while
   the chat model downloads.
2. In **Talk to your local model by voice**, choose a speech model or select
   **Skip — I’ll type** to leave voice off. The two English picks are
   **Recommended** — Parakeet Unified English 0.6B (697 MB), and
   **More accurate** — Qwen3-ASR 1.7B (2.0 GB).
3. Start the speech model download with the button that shows its size, such as
   **Download 697 MB**, then select **Finish setup**. The picker says **Downloads
   while you finish setup**. You can pause and resume the transfer. Quenderin
   verifies the file’s SHA-256 before you can dictate with that model.

## Compare speech models

Open **Show all 29 models** to search Handy’s curated on-device speech catalog.
**Live preview** filters for models with streaming support and **Translates**
filters for models with speech translation support.

| Column | What it shows |
| --- | --- |
| **EN** | English accuracy grade (A–F) based on Handy’s word error rate on the FLEURS test set. `?` marks a missing measurement. `—` marks a model without claimed English support. |
| **SPEED** | More bars mean a shorter estimated wait for 30 seconds of dictation on Handy’s AMD Ryzen 4750U GPU benchmark (Vulkan). |
| **SIZE** | How much you’ll download for the selected speech model. |

Quenderin ran no inference benchmarks for this update. Speed on your computer
depends on your hardware. [See Handy’s published benchmarks](https://models.handy.computer/).

## Dictate into chat

When the speech model is installed and enabled, hold the microphone button in
the chat composer and speak. You can also hold **Ctrl+Shift+M** or **⌘+Shift+M**.
Allow microphone access when prompted, then release to transcribe.

Your audio stays on your computer and `transcribe.cpp` turns it into text locally.
The transcript appears in the composer, where you can edit it before sending it
to the local chat model. The model downloads need a connection. With both models
installed, local dictation and chat are designed to work offline.

Open **Settings → Voice** to pick a different speech model. Select **Use this
model** if it’s already installed. Here you can also toggle **Enable voice
dictation** or **Automatically send transcript**. If the app can’t open the
microphone, check microphone permissions and the input device in system settings.

## Credits

Quenderin adapts the picker and download handling from Handy by CJ Pais (MIT)
and uses `@handy-computer/models` 0.2.3 (MIT) for the catalog and recommendations.
The picker lists each model’s license. [Handy](https://github.com/cjpais/Handy) ·
[@handy-computer/models](https://github.com/handy-computer/models) ·
[Desktop voice update](../website/blog-local-voice.html)
