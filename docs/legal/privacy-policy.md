# Quenderin — Privacy Policy

_Last updated: 2026-10-28_
_Contact: quenderin@aulenor.com_

> Public policy: https://quenderin.org/privacy. Keep this source and the hosted policy consistent.

## The short version

Quenderin's **local chat, image, and memory features process content on your device**.
Optional **DeepSeek**, **My computer / Remote Harness**, and **Step 5 CUDA-host** features send
data to the provider, server, or computer you choose, as described below. Their conversations
are separate from local chats; local chats, attachments, and memory are not automatically
uploaded to them. Quenderin does not provision a hosted AI service. Model discovery,
downloads, and the website also make network requests.

## 1. Who we are (Data Controller)

The controller responsible for personal data described here is The Quenderin Project.
Address: available on request. Contact and data protection contact:
[quenderin@aulenor.com](mailto:quenderin@aulenor.com).

## 2. The app: local features and optional connections

Optional features described here apply only to app versions that include them.

- **Local chat.** Installed local models process prompts and conversations on your device.
  After the required model files are installed, local inference can run offline.
- **Images and attachments.** Local image generation and image or attachment processing happen
  on your device. The optional direct DeepSeek and Step 5 conversations accept text, not local
  image or file attachments.
- **Hy-Memory.** This local feature proposes facts from the conversation you choose to review.
  Proposals start unselected; only those you select and approve are saved in the app's private
  local memory storage. Nothing is saved automatically.
- **Accounts.** Local features require no Quenderin account. Direct DeepSeek uses your existing
  DeepSeek API account. Remote Harness signs into an existing account on the server you
  configure; it does not create that account. Quenderin does not provide automatic cloud sync.
- **App diagnostics.** Quenderin does not send app usage analytics, telemetry, or crash reports
  to the Quenderin Project.

User-enabled operating-system or device backups may include local app data on Apple devices;
these are separate from Quenderin, which does not provide automatic cloud sync.

### Optional direct DeepSeek connection

When you choose to validate and save a DeepSeek connection, the app sends your API key over
HTTPS directly to `api.deepseek.com/models` to check available models. This check does not
send a conversation or make a paid inference request. The saved key is protected in Apple's
device-only, non-synchronizing Keychain, or encrypted using Android Keystore on Android.
Protecting the saved key does not prevent DeepSeek from receiving it for authentication.

After you approve using a separate DeepSeek conversation and choose **Send**, the app sends
your new text and that conversation's completed earlier messages, including returned reasoning
when present, directly to `api.deepseek.com/chat/completions`. The request also contains the
selected model, thinking settings, and output limits, and authenticates with your API key.
The direct connection does not enable tools or attach local chats, files, images, or memory.
DeepSeek receives ordinary connection information such as your IP address and can associate
requests with your API account. Inference uses that account and may incur provider charges.

The app saves this separate conversation locally, including answers, reasoning, incomplete
turns, model settings, usage counts, and connection references. Removing the connection or
saved API keys keeps the saved conversations. The current DeepSeek screens do not offer
per-conversation deletion. There is no automatic expiry of saved DeepSeek history.

DeepSeek controls its handling of requests under the terms applicable to your account,
including its [Open Platform terms](https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html).
Quenderin does not set DeepSeek's retention period or promise that API data is never retained
or used for other purposes. Removing a key or local data does not delete provider records or
close your DeepSeek account; use the provider's account and privacy-request channels for those
requests. You can stop further direct sends by removing the connection or choosing not to send.

### Optional My computer / Remote Harness connection

You enter the HTTPS origin of your Remote Harness server and choose **Authorize this device**.
Sign-in sends the account email and password you enter to that server. Device enrollment sends
a generated device identifier, device name, platform, public identity key, and client version.
The password is used for sign-in rather than saved as a credential. The app stores a private
device identity and rotating access and refresh tokens in a separate Apple Keychain record or
Android Keystore-encrypted storage. Tokens are sent to the configured server to authenticate
connections and renew authorization.

You choose a computer and verify its full identity fingerprint; the computer must also
authorize this device. Session payloads are encrypted between the app and that computer using
the Noise protocol. The server still handles account and device records, connection and
routing identifiers, public keys, and ordinary network information such as IP addresses,
connection times, and traffic sizes. This session encryption does not hide sign-in or enrollment
data from the server, or hide decrypted session content from the selected computer.

Choosing **Send** sends the task text, session and command identifiers, and client time-zone
context to the selected computer. Other actions send their corresponding session commands,
model selections, or one-time tool approval decisions. The app can receive workspace paths,
session history, answers, reasoning, tool events and approval details, and bot information
from that computer. Tasks and tools run on the computer; its configured AI providers, tools,
and services may receive data according to the task and its configuration. The app does not
automatically import local chats or its direct DeepSeek API key into this connection.

The app saves connection details, trusted fingerprints, selected sessions, drafts, received
history, and command recovery records separately on this device. These records have no
automatic expiry. An authorized connection may reconnect and refresh remote history when
the app returns to the foreground. **Disconnect** stops the connection and automatic recovery;
it keeps saved credentials, drafts, and history. It does not delete the server account, revoke
the device's server authorization, stop an already-running task, or delete computer/provider
records. The server administrator and computer operator control their own records and
deletion; contact them and any downstream provider about retained copies.

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
  ordinary download of a public file. Hugging Face receives the requested file and ordinary
  connection information, including your IP address, and may log the request under
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
- Saved DeepSeek and Remote Harness records are separate from local chats. Their history
  directories are excluded from app-managed backups; saved credentials use the protections
  described above. This does not erase data already sent to a remote destination.
- Step 5's separate conversation is held in app memory. Deleting local data does not delete
  content already received by the host you chose.

### AI-generated content

Responses are produced by a model running locally, by DeepSeek, or by your chosen computer
or Step 5 host. Output may be inaccurate, offensive, or
otherwise objectionable. Do not rely on it for professional, legal, medical, or financial advice.

In **Android app versions with a Report control**, you can select a response, edit the
excerpt, choose a reason, and add an optional note. Only when you choose **Send report** does
the app send that excerpt, reason, note, source feature, a random report identifier, platform,
and app version to the Quenderin developer's **Google Apps Script inbox** for manual review.
The inbox adds a receipt identifier and received time. Reporting requires no Quenderin or
Google account. The app adds no account or device identifier to the report.

The app does not automatically attach your whole conversation, attachments, memory, API keys,
or diagnostics to a report. Review the text before sending, because it may contain personal
information you choose to include. Google hosts the report storage and processes ordinary
connection information, such as your IP address and request time, under
[Google's privacy policy](https://policies.google.com/privacy). Processing may occur outside
your country; this feature does not guarantee a particular storage location.

The developer keeps submitted reports for review, without automatic expiry. Clearing a chat
or removing local app data does not delete a report already sent. For access, correction, or
deletion requests, contact [quenderin@aulenor.com](mailto:quenderin@aulenor.com); include the
report receipt if available so we can identify the report.

If you choose to email support or report a response through an email action, your email
application prepares the message for you to review and send. The support address receives
the content you send and the email's ordinary sender and delivery information. Opening that
action is separate from sending a report.

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
of sale/sharing of personal information. We do not sell personal information. Optional transfers
to the recipients described above occur when you use those features.

To exercise any right, contact [quenderin@aulenor.com](mailto:quenderin@aulenor.com). You control
data stored locally on your device through the available app and operating-system controls;
contact us for help with saved data that has no in-app deletion control. Removing a connection
or clearing local data does not erase records held by DeepSeek, a Remote Harness server or
computer, a Step 5 host, or services used by that computer. Contact the relevant operator or
provider about access, retention, and deletion of those records.

## 6. Children

Quenderin is not directed to children under 16 (or the applicable age in your country), and we
do not knowingly collect personal data from them.

## 7. International transfers

Local inference does not transfer your content for processing. Website requests, model
discovery, and downloads may be processed outside your country by the providers described
above. Optional DeepSeek requests are sent to DeepSeek's infrastructure; Remote Harness sign-in
and device records go to the server you configure, and session content goes to the selected
computer and any services it uses. Step 5 text goes to your selected host. These destinations
may be in another country. Processing locations and safeguards depend on the provider or
operator; local storage and session encryption do not guarantee a particular remote location.

## 8. Changes

We may update this policy; the "Last updated" date will change accordingly. Material changes
will be reflected here.

## 9. Contact

Questions or requests: [quenderin@aulenor.com](mailto:quenderin@aulenor.com).
