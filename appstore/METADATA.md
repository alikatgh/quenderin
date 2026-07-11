# App Store listing — Quenderin (v0.2.0, build 2) — iOS + macOS universal

Paste-ready. Universal purchase: ONE app record, bundle `ai.quenderin.Quenderin`, both platforms.
Team 9M2B2P4KSA. Signed artifacts: `apple/QuenderinApp/build/export-ios/Quenderin.ipa` + `export-mac/Quenderin.pkg`.
Category: **Productivity**. Free. Privacy label: **Data Not Collected**.

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
Quenderin is an AI that runs entirely on your device — no account, no cloud, no
tracking. After a one-time model download, every token is generated locally via
llama.cpp; nothing you type ever leaves your iPhone or Mac.

• Chat with an on-device language model — pick from a curated catalog (0.4–13 GB)
  sized to your device, or bring any GGUF from Hugging Face
• A private, governed computer-use agent: give it a goal, it plans and uses
  on-device tools — every action that changes something asks you first
• Works fully offline after the download — on a plane, off the grid, anywhere
• Interface in English, Russian, Korean, Japanese, and Chinese
• No sign-in, no ads, no telemetry — conversations stay on the device

Quenderin is honest about the trade-offs: small on-device models can be wrong or
outdated, and the app says so plainly. It is a private alternative to cloud AI,
not a replacement for a qualified professional.
```

## Description (ru)

```
Quenderin — это ИИ, который работает целиком на вашем устройстве: без аккаунта,
без облака, без слежки. После однократной загрузки модели каждый токен
генерируется локально через llama.cpp — ничто из введённого не покидает ваш
iPhone или Mac.

• Чат с локальной языковой моделью — выберите из подобранного каталога
  (0,4–13 ГБ) под ваше устройство или загрузите любой GGUF с Hugging Face
• Приватный управляемый агент: поставьте задачу — он строит план и использует
  локальные инструменты, а каждое изменяющее действие сначала спрашивает вас
• Полностью работает офлайн после загрузки — в самолёте, вне сети, где угодно
• Интерфейс на английском, русском, корейском, японском и китайском
• Без входа, рекламы и телеметрии — беседы остаются на устройстве

Quenderin честен о компромиссах: небольшие локальные модели могут ошибаться или
устаревать, и приложение об этом прямо предупреждает.
```

## Keywords (100 chars, en)
```
ai,chat,llm,offline,private,on-device,assistant,local,llama,gguf,no cloud,agent,privacy
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
- **Data Not Collected** — matches PrivacyInfo.xcprivacy (no tracking, no collected
  types; only required-reason DiskSpace/FileTimestamp for the model-fit checks).

## App Review notes (paste for the reviewer)

```
Fully on-device AI. After a one-time model download (in-app, from Hugging Face)
there is no server component and no network use — all inference is local via
llama.cpp. No account or sign-in.

To review: launch → accept the "Use with judgement" disclaimer → on the model
screen tap "Llama 3.2 1B Ultra-Light" (0.4 GB, fastest to download on Wi-Fi) →
Download & continue → chat. The agent tab is optional and every mutating tool
asks for per-action approval.

AI-generated content: on-device models are small and can be wrong; a prominent
disclaimer is shown at first launch and the app never claims to give medical,
legal, or financial advice. Interface language follows the system (Settings →
per-app language on iOS 16+/Android 13+).
```

## Screenshots
- iPhone 6.5" (1284×2778 JPEG) + 6.9" (1320×2868): `appstore/screenshots/iphone-{en,ru}-*`
  (chat / models / agent / settings, en + ru)
- iPad: N/A (iPhone-only this release; TARGETED_DEVICE_FAMILY=1)
- **Mac**: still to capture (needs the app-control grant, or capture in Screenshot.app)

## Remaining steps (once you're ready — submission is currently HELD)
1. App Store Connect → My Apps → **+** → New App → iOS **and** macOS platforms,
   name "Quenderin", bundle `ai.quenderin.Quenderin`, SKU `quenderin`.
2. Tell me → I upload both builds (`ExportOptions.plist` destination=upload) and
   fill the whole listing in your browser.
3. Capture Mac screenshots (re-grant app control, or you do it), answer age +
   privacy questionnaires, select builds, Submit for Review.
