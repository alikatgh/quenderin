# November 2026 Kromoss, Hex speech, and docs portal update

Social publication archive for the 22 November 2026 Quenderin rollout on
[`quenderin.org`](https://quenderin.org) and `main` revision
`22bc629f4df676b114960bc57ffc12bb2d3b88f8`.

## Editorial artwork

Generated in the continuing Quenderin ChatGPT artwork thread
[Generate Header Image Prompt](https://chatgpt.com/c/6acc6673-0a78-83e8-9b0e-fa8c3c6b013a)
(ChatGPT file ID `file_0000000095f48211a9d4d9ef9eaf90c9`, original download
`~/Downloads/Enchanting Workshop by the Waterfalls.png`).

- Deliverable PNG: `quenderin-kromoss-hex-docs.png` (1536 × 1024, 2,793,659 bytes)
- SHA-256: `a767b91516449651c8fa451b452b9bbc2cca74eac2ae7606f7c8d82ab1bed3df`
- Alt text: `Editorial illustration of developers and a teal-and-copper braided elf collaborating on local image generation tablet artwork, a desktop microphone receiver, and engineering documentation folios overlooking a sunlit waterfall city.`

## Live website & Cloudflare state

Cloudflare Web Analytics (`quenderin.org`) was changed from `Enable, excluding visitor data in the EU` to `Disable` while keeping the `quenderin` Worker Custom Domain and routes active. Seven live endpoints returned HTTP `200` with `0` `cloudflareinsights.com/beacon.min.js` injections:

- `https://quenderin.org/` (`10,316` bytes, SHA-256 `8fea483b273bd0f4864089343e50f2e951f0b07eca120e571a4ec791f469210d`)
- `https://quenderin.org/tell-me-more` (`78,951` bytes, SHA-256 `c175bcff6f7daa2243411e8317f36dafdc9d9cb97a499c1395e2ebeee6693a9b`)
- `https://quenderin.org/blog-kromoss-hex-november-2026` (`9,112` bytes, SHA-256 `88a5bd504099fd5dd45452fdefcbd85f8fff0433149f3334e8ef74c329778939`)
- `https://quenderin.org/blog-website-fonts-docs-november-2026` (`8,182` bytes, SHA-256 `d0b3d48a0002c29fd928053eeb225397de835cc45ebebccb0f8a1dd816d8990f`)
- `https://quenderin.org/docs/` (`33,319` bytes, SHA-256 `d6342838b26a21d85290c7634798e1f07267f181ef407d1b15bb2f0860e976ea`)
- `https://quenderin.org/docs/models-catalog` (`37,029` bytes, SHA-256 `2cb2236af48835d8a89f16ee03f375df6545e4f440b99ea682c68029080e601e`)
- `https://quenderin.org/data/model-catalog.json` (`27,070` bytes, SHA-256 `391bfe938d841ebb96e18e2c42f3fb12e5de94785b41f06a496b713518064123`)

Live homepage screenshot: `homepage-live.png` (2994 × 1602, 4,751,581 bytes, SHA-256 `44f7c4ce7260026e58e416d45fe890302901cd6a844aaff4776eb1494ade9829`).

## Published social posts (once per network)

- **Facebook (`Quenderin`, page ID `1185788367957208`)**: [Live post](https://www.facebook.com/quenderin/posts/pfbid0AbePC2QDNKijgSaGWZbhiJnF5Y8ds26Acr8eynXvjb4dR85wYz3LGjZGCEwfEoJPl) — audience `Public`, `AI label on` (`AI content` displayed), Boost off, zero duplicates. Proof screenshot: `facebook-live.png` (1400 × 2572, 2,890,224 bytes, SHA-256 `e473e280c5dcb0a4dc727fc42bc1558b25c6f3e138581b440ee0e500bd129cad`).
- **LinkedIn (`Quenderin`, company `135196272`)**: [Canonical activity](https://www.linkedin.com/feed/update/urn:li:activity:7530296322130878464/) / [Share permalink](https://www.linkedin.com/feed/update/urn:li:share:7530296321057091584/) — audience `Anyone`, C2PA Content Credentials intact (`cr` badge), link rendered as `https://lnkd.in/dMqmKfsA`, Boost off, zero duplicates. Proof screenshot: `linkedin-live.png` (1110 × 2392, 1,906,370 bytes, SHA-256 `19e76c3ed83d1efae7cf5970dbd50bd30d42bc6a18e07a080537f5120752575f`).

### Published copy

> Kromoss local images, native Hex speech, and a 30-page documentation portal — November 22 Quenderin update.
>
> On quenderin.org today, we shipped our rebuilt 30-page self-hosted documentation portal, self-hosted ChunkFive and DINish typography, a redesigned feature showcase (/tell-me-more), and full 12-language homepage translation parity.
>
> In source engineering on GitHub, two new multimodal building blocks are now wired across our cross-platform native stack (Desktop, Apple QuenderinKit, and Android quenderin-core):
> - Kromoss (Apache-2.0): standard and 8-step DMD2 LoRA local image generation on native/diffusion C ABI v2, sharing existing Qwen3.5-9B / Flux2 VAE / MOSS encoders without duplicate downloads.
> - Hex + transcribe.cpp (MIT): 20 pinned offline speech-recognition presets plus Silero VAD v6.2 on an isolated native/speech C ABI, Desktop loopback v2, and deterministic cross-platform dictation formatting.
>
> This is a source and website update, not a new app-store release. Hosted toolchains verified catalog parity, SHA-256 manifests, symbol-isolated C/C++ builds, Swift/Kotlin compilation, and TypeScript unit suites, while live end-user weight inference (inferenceVerified: false) and physical device UI checks remain separate. Mac and iPhone on the App Store remain 0.6.0, Android closed beta remains 0.2.0, and desktop installers remain v0.2.1.
>
> https://quenderin.org/blog-kromoss-hex-november-2026
>
> Artwork: AI-generated editorial illustration.

## Engineering vs store boundary

- Canonical catalog parity passed across all 28 models (`ALL PLATFORMS MATCH THE CANONICAL MANIFEST`).
- Source-level multimodal integrations remain marked `inferenceVerified: false`; no model weights were downloaded and no simulator or physical-device runs were executed in this release cycle.
- Public store availability is unchanged: App Store `0.6.0` (`0.6.1` unsubmitted), Google Play Closed testing - Alpha `2 (0.2.0)`, Desktop GitHub releases `v0.2.1`.

See `publication-verification.json` for structured digests without credentials.
