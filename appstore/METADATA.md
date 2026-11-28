# App Store listing — Quenderin (iOS and macOS)

Draft copy for the existing app record, bundle `ai.quenderin.Quenderin`, on both
platforms. Verify the copy and form answers against the selected builds.
Use **Productivity** as the category and set the price to free.

## Name & subtitle (30 chars max)

| Field | Value | Chars |
|---|---|---|
| Name | `Quenderin` | 9 |
| Subtitle (en) | `Private on-device AI chat` | 25 |
| Subtitle (ru) | `Приватный ИИ на устройстве` | 26 |

## Primary language
English (localized to Russian, Korean, Japanese, Simplified Chinese in-app).

## Description (en)

```
With Quenderin, you can chat with a local AI model on your iPhone or Mac. After
you download a model, local chat works offline and needs no account. Your local
conversations stay on your device.

• Chat with an on-device language model — pick from a curated catalog (0.4–13 GB)
  sized to your device, or bring any GGUF from Hugging Face
• A private, governed computer-use agent: give it a goal, it plans and uses
  on-device tools — every action that changes something asks you first
• Interface in English, Russian, Korean, Japanese, and Chinese

Optional online connections such as DeepSeek, My computer and Step 5 send
separate conversations or tasks to the destination you select.

Quenderin is honest about the trade-offs: small on-device models can be wrong or
outdated, and the app says so plainly. It is a private alternative to cloud AI,
not a replacement for a qualified professional.
```

## Description (ru)

```
В Quenderin можно общаться с локальной моделью ИИ на iPhone или Mac. После
загрузки модели локальный чат работает без интернета и учётной записи.
История локального чата хранится на устройстве.

• Чат с локальной языковой моделью — выберите из подобранного каталога
  (0,4–13 ГБ) под ваше устройство или загрузите любой GGUF с Hugging Face
• Приватный управляемый агент: поставьте задачу — он строит план и использует
  локальные инструменты, а каждое изменяющее действие сначала спрашивает вас
• Интерфейс на английском, русском, корейском, японском и китайском

При использовании дополнительных сетевых подключений, таких как DeepSeek,
My computer и Step 5, отдельные беседы или задачи отправляются на выбранный
сервис или компьютер.

Quenderin честен о компромиссах: небольшие локальные модели могут ошибаться или
устаревать, и приложение об этом прямо предупреждает.
```

## Keywords (100 chars, en)
```
ai,chat,llm,offline,private,on-device,assistant,local,llama,gguf,agent,privacy
```

## URLs (all verified 200)
- Support: `https://quenderin.org/help`
- Marketing: `https://quenderin.org`
- Privacy Policy: `https://quenderin.org/privacy`

## Age rating questionnaire — answer honestly
- **Unrestricted AI-generated content**: this app generates open-ended text from a
  user-controllable model → answer the AI content items **Yes / present**.
- Expect **17+** (open-ended generative AI with no server-side content filter is
  the driver). Everything else: None.
- Have the review note (below) ready — it explains the on-device disclaimer.

## App Privacy (nutrition label)

Review the Apple privacy manifest and the optional connections in the selected
builds before completing the privacy label. [Store submission checklist](../docs/STORE_SUBMISSION.md#3-privacy-label-recommendations-and-unresolved-answers)

## App Review notes (paste for the reviewer)

```
Local chat runs on-device via llama.cpp and works offline without an account
after an in-app model download from Hugging Face.

My computer is a separate, optional online connection. It uses an existing
account on a configured Remote Harness server to connect to a trusted computer.
DeepSeek and Step 5 are separate optional online connections.

To review: launch → accept the "Use with judgement" disclaimer → on the model
screen tap "Llama 3.2 1B Ultra-Light" (0.4 GB, fastest to download on Wi-Fi) →
Download & continue → chat. The agent tab is optional and every mutating tool
asks for per-action approval.

AI-generated content: on-device models are small and can be wrong; a prominent
disclaimer is shown at first launch and the app never claims to give medical,
legal, or financial advice. Interface language follows the system (Settings →
per-app language on iOS 16+/Android 13+).
```

## Export compliance

Offline local chat uses a separate path. The optional **My computer** connection
protects remote session payloads with bundled Snow and Noise IK (X25519,
ChaCha20-Poly1305 and SHA-256) outside Apple's OS crypto. The final App Store
Connect encryption declaration and France filing or exemption determination
remain pending with Albert for the selected builds.
[Export compliance checklist](../docs/EXPORT_COMPLIANCE.md) · [Issue #217](https://github.com/alikatgh/quenderin/issues/217)

## Screenshots
- iPhone 6.5" (1284×2778 JPEG) + 6.9" (1320×2868): `appstore/screenshots/iphone-{en,ru}-*`
  (chat / models / agent / settings, en + ru)
- iPad: N/A (iPhone-only this release; TARGETED_DEVICE_FAMILY=1)
- **Mac**: still to capture (needs the app-control grant, or capture in Screenshot.app)

## Submission checklist

Use the existing App Store Connect record. Match the screenshots, listing,
review notes, age rating and privacy answers to the selected builds.
[Store submission checklist](../docs/STORE_SUBMISSION.md)
