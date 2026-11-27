# Local voice on desktop

This guide covers the unreleased desktop dashboard integration. Release
verification still needs a real microphone, full speech model weights, and
packaged Electron builds.

## Set up voice

1. In **Choose your local chat model**, pick the model that will answer your
   messages. Select **Next: Voice** or **Continue while downloading**. To defer
   an uninstalled chat model before starting its download, select **Set up chat later**.
2. In **Talk to your local model by voice**, choose a speech model or select
   **Skip — I’ll type** to leave voice off. The two English picks are
   **Recommended** — Parakeet Unified English 0.6B (697 MB), and
   **More accurate** — Qwen3-ASR 1.7B (2.0 GB).
3. Start the download with the size-labeled button, such as **Download 697 MB**.
   The picker says **Downloads while you finish setup**. Select **Finish setup**
   while the download is running or once the model is installed. Use **Pause**
   and **Resume** to control the transfer. Quenderin verifies the file’s SHA-256
   before installing it.

## Compare speech models

Open **Show all 29 models** to search Handy’s curated on-device speech catalog.
**Live preview** filters for models with streaming support and **Translates**
filters for models with speech translation support. These labels describe model
capabilities. Push-to-talk transcribes after you release the control. Models
marked **Needs newer speech engine** require a later runtime.

| Column | What it shows |
| --- | --- |
| **EN** | English accuracy grade based on Handy’s word error rate on the FLEURS test set. `?` marks a missing measurement. `—` marks a model without claimed English support. |
| **SPEED** | More bars mean a shorter estimated wait for 30 seconds of dictation on Handy’s AMD Ryzen 4750U GPU benchmark (Vulkan). |
| **SIZE** | How much you’ll download for the selected speech model. |

Quenderin ran no inference benchmarks for this update. Speed on your computer
depends on your hardware. [See Handy’s published benchmarks](https://models.handy.computer/).

## Dictate into chat

With a speech model installed and enabled, hold the **Hold to talk** microphone
button in **Chat** or **Device Agent**. You can also hold **Ctrl+Shift+M** on
Windows or Linux, or **⌘+Shift+M** on macOS, while the composer is available.
If a permission prompt interrupts the gesture, allow microphone access and hold
again. Speak, then release to transcribe.

The local dashboard requires authentication for speech settings, downloads,
and transcription. The release review also calls for authentication when
reading installed-model status. The `transcribe.cpp` runtime processes the
audio on the same computer. Model downloads need an internet connection. With
the required models installed, dictation and local chat are designed to work
offline.

By default, Quenderin adds the transcript to your draft. In **Chat**, you can
edit it before sending it to your selected chat model. In **Device Agent**, you
can edit the goal before selecting **Run agent goal**.

## Manage voice settings

Open **Settings → Voice** to toggle **Enable voice dictation** or
**Automatically send transcript**. The release plan limits automatic sending to
**Chat** and keeps **Device Agent** goals in the draft until you select **Run agent
goal**. Select **Use this model** to switch to a different installed speech model.
To free disk space, select **Remove model**, then **Confirm removal**.

## Allow microphone access

- **Windows.** In Windows 11, open **Settings → Privacy & security → Microphone**.
  Turn on **Microphone access**, **Let apps access your microphone**, and
  **Let desktop apps access your microphone**. On Windows 10, open
  **Settings → Privacy → Microphone** and enable access for the device, apps,
  and desktop apps. [Microsoft microphone settings](https://support.microsoft.com/en-us/windows/privacy/turn-on-app-permissions-for-your-microphone-in-windows)
- **Linux.** In your desktop’s sound settings, select and unmute the microphone
  under **Input**. Speak and check that the input level moves. The exact path
  depends on your desktop environment. [GNOME microphone settings](https://help.gnome.org/gnome-help/sound-usemic.html)
- **macOS Electron lab builds.** Allow Quenderin in **System Settings → Privacy
  & Security → Microphone**, then reopen the app. A signed lab build also
  requires the `com.apple.security.device.audio-input` entitlement. [Apple microphone settings](https://support.apple.com/en-ie/102071) · [Audio input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input)

If you open the local dashboard in a browser, allow microphone access in that
site’s permissions as well as in your operating system. Check the selected
system input if Quenderin reports that it can’t find a microphone.

## Credits

Quenderin adapts the picker and download handling from Handy by CJ Pais (MIT)
and uses `@handy-computer/models` 0.2.3 (MIT) for the catalog and recommendations.
The picker lists each model’s license. Open **Voice credits and licenses** in
**Settings → Voice** for the third-party notices. [Handy](https://github.com/cjpais/Handy) ·
[@handy-computer/models](https://github.com/handy-computer/models) ·
[Desktop voice update](../website/blog-local-voice.html)
