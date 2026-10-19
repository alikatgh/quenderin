# Quenderin — Privacy Policy

_Last updated: 2026-10-19_
_Contact: quenderin@aulenor.com_

> Public policy: https://quenderin.org/privacy. Keep this source and the hosted policy consistent.

## The short version

Quenderin's **local chat, image, and memory features process content on your device**.
In app versions with the optional **Step 5 CUDA-host feature**, text entered in its separate
conversation is sent to the host you configure only after you approve sending. Quenderin does
not provide a hosted AI service or automatically upload your local conversations. Model
discovery, downloads, and the website make the network requests described below.

## 1. Who we are (Data Controller)

The controller responsible for personal data described here is The Quenderin Project.
Address: available on request. Contact and data protection contact:
[quenderin@aulenor.com](mailto:quenderin@aulenor.com).

## 2. The app: local features and an optional host

Optional features described here apply only to app versions that include them.

- **Local chat.** Installed local models process prompts and conversations on your device.
  After the required model files are installed, local inference can run offline.
- **Images and attachments.** Local image generation and image or attachment processing happen
  on your device. Step 5 accepts text entered in its separate conversation; it does not
  automatically attach your local chats, images, files, or memory bank.
- **Hy-Memory.** This local feature proposes facts from the conversation you choose to review.
  Proposals start unselected; only those you select and approve are saved in the app's private
  local memory storage. Nothing is saved automatically.
- **No Quenderin cloud account.** There is no app account, sign-in, or automatic cloud sync.
  Quenderin does not provide or provision a cloud AI service.
- **App diagnostics.** Quenderin does not send app usage analytics, telemetry, or crash reports
  to the Quenderin Project.

User-enabled operating-system or device backups may include local app data on Apple devices;
these are separate from Quenderin, which does not provide automatic cloud sync.

### Optional Step 5 CUDA host

You configure the gateway origin for your own CUDA host. Checking its backend contacts that
host without sending conversation content. If you enable the consent control and choose
**Send to CUDA host**, the request contains your current prompt and the preceding messages in
that separate Step 5 conversation. Local chat history is not automatically copied into it.
The configured origin and Step 5 conversation are held in app memory rather than saved as
local chat history.

The host receives that text and ordinary connection information, such as your IP address.
Its operator controls how it processes, logs, retains, or deletes received data under its
own policies and configuration. Quenderin does not control that host. You can disable consent
to prevent further sends; changing the host resets consent. Clearing the conversation in
the app does not delete copies the host may already hold.

### Model discovery and downloads

These features use network requests independently of local inference:

- **Model downloads.** When **you choose to download a model**, the app fetches the model file you
  selected directly from **Hugging Face** (`huggingface.co`), a public model host. This is an
  ordinary download of a public file — **no information about you is sent** beyond what any
  download requires (your device's IP address is visible to Hugging Face, as with any web
  request). That connection is governed by
  [Hugging Face's privacy policy](https://huggingface.co/privacy).
- **Model-catalog search (optional).** If you search for a model to download, the search term you
  type is sent to Hugging Face's public model index to find matching files. Nothing else is
  attached to that request — no conversation content, no account, and no identifiers beyond what
  any web request carries. Search terms are used only to return catalog results and are never
  stored by us.
- **Latest release metadata.** In app versions with the latest-releases view, opening model
  selection checks a small public catalog at `quenderin.org/api/model-releases`. No conversations,
  files, account, device profile or search terms are sent. Our hosting provider processes ordinary
  request information, such as IP addresses, for routing and security. Results are saved on your
  device for offline browsing; the request never downloads weights or changes your active model.

### Data stored on your device

- Conversations and app settings are stored locally in the app's private container.
- Downloaded models are stored locally and can be several gigabytes.
- Approved Hy-Memory proposals are saved separately in private local memory storage.
- Step 5's separate conversation is held in app memory. Deleting local data does not delete
  content already received by the host you chose.

### AI-generated content

Responses are produced by a language model running locally, or by your chosen host when you
use Step 5. Output is **not curated or filtered by us** and may be inaccurate, offensive, or
otherwise objectionable. Do not rely on it for professional, legal, medical, or financial advice.

## 3. This website

The website stores an appearance preference in your browser's local storage. It has no sign-up
form. Our hosting provider, Cloudflare, processes ordinary request information such as IP
address, time, and page requested for delivery, security, and operation under its
[privacy policy](https://www.cloudflare.com/privacypolicy/). The site's current Content Security
Policy blocks third-party analytics scripts and outbound analytics connections. We do not use
this site to build advertising profiles.

## 4. Following the project

This site collects no newsletter email addresses. You can follow the project on
[GitHub](https://github.com/alikatgh/quenderin). GitHub processes activity there under
[its own privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement);
public activity, such as starring the repository, may be visible to others.

## 5. Your rights

Under the GDPR/UK GDPR you have the right to access your data, rectify it, erase it, restrict or
object to processing, data portability, and to withdraw consent at any time. You also have the
right to lodge a complaint with your local data protection supervisory authority.

Under the CCPA/CPRA, California residents have the right to know, delete, correct, and opt out
of sale/sharing of personal information. We do not sell or share personal information.

To exercise any right, contact [quenderin@aulenor.com](mailto:quenderin@aulenor.com). You control
data stored locally on your device through the app's storage and deletion controls. For content
you send to a Step 5 host, contact that host's operator about its retained copies; clearing local
app data does not remove them.

## 6. Children

Quenderin is not directed at children. Because it can generate unrestricted AI text, it is rated
for ages 17+.

## 7. International transfers

Local inference does not transfer your content for processing. Website requests, model
discovery, and downloads may be processed outside your country by the providers described
above. If you choose a Step 5 host in another country, the prompt and preceding Step 5 messages
you approve sending are transferred there. The location and handling of that data depend on
the host you choose and its operator's policies.

## 8. Changes

If this policy changes, the "Last updated" date above will change. Continued use after an update
means you accept the revised policy.

## 9. Contact

Questions or requests: [quenderin@aulenor.com](mailto:quenderin@aulenor.com).
