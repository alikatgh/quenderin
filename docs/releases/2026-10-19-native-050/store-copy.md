# Native 0.5.0 store copy

Prepared text for the exact signed 0.5.0 candidate. This file does not establish
upload, submission, approval or availability.

## Apple description — iOS and macOS

Quenderin runs open language models on your device. Download a compatible model,
then use local chat offline. No app account, ads or analytics are required.

- Choose from a model catalog with download sizes, compatibility checks and
  memory estimates. Experimental choices are selected manually.
- Browse compatible model files on Hugging Face and filter downloads by size.
- Use dedicated workflows for still-image questions, reviewed memory proposals,
  verified Granite imports and local image generation on suitable hardware.
- Keep local conversations on your device. Hy-Memory facts are saved only after
  you select and approve them.
- Optionally connect Step 5 to your own prepared CUDA host. Its separate text
  conversation is sent to that host only after you approve sending. Quenderin
  does not provide or provision a hosted AI service.

Large models require complete downloads and substantial memory. Some specialist
workflows are unavailable on ordinary phones. The app checks resources before
loading; file size and active parameter count are not RAM requirements.

Internet access is needed for downloads and model discovery. Local inference
works offline after setup; optional Step 5 requires a connection to your host.
On-device and remote models can make mistakes. Check important answers.

## Apple What's New — iOS and macOS

Expanded the experimental text catalog with MiniCPM-V 4.7, LFM2.5, Jais 3 and
Nemotron 3.5 Bolt, plus complete multipart Beam and Muse installation.

Added separate workflows for one-image questions, approved Hy-Memory proposals,
verified Granite Switch 4.1 imports and local image generation on compatible
high-memory hardware. Added an optional Step 5 connection to your own prepared
CUDA host, with approval before sending its conversation.

Improved compatibility, resource and complete-file checks. Clarified local and
optional remote processing in the app and privacy policy.

## Apple review notes

No sign-in or review account is required. For ordinary chat, use Models to choose
and explicitly download a small compatible model over Wi-Fi. Local chat works
offline after that download. Please do not download large workstation models
for the basic review path.

The Images destination is separate from text chat. Settings exposes the
still-image, Hy-Memory, Granite and Step 5 workflows. Before chat setup, More
models also offers the specialist entry points. Resource gates intentionally
make models unavailable when the current device cannot fit them.

Beam needs all four files, about 133.89 GB, and at least 160 GiB available memory
before context overhead. Muse needs all 22 files, about 304.08 GB. These choices
are manual and unsuitable for an ordinary iPhone. No model downloads or host
provisioning start automatically.

Step 5 uses the user's existing Linux CUDA host through a secured gateway.
Its own prompt/history are sent only after the explicit consent control is
enabled and Send to CUDA host is chosen. Ordinary local chat history, images,
attachments and saved memories are not automatically attached. No Quenderin
remote service or review credential is provided.

Engineering checks and hosted compilation are recorded in the release evidence.
Full-weight inference, image quality, measured peak memory/speed and native
rendered journeys for the additions have not been validated in this update.
No device, simulator or local model-weight run is claimed.

## Google Play closed-test release notes

Expanded experimental models and complete Beam/Muse installation. Added separate
vision, reviewed memory, Granite import and local image workflows with hardware
checks. Optional Step 5 sends its separate text conversation to your own CUDA
host only after approval. Improved resource checks and private-memory backup
exclusions. Large specialist models require suitable hardware.
