# Quenderin — Privacy Policy

_Last updated: [FILL DATE before publishing]_
_Contact: [FILL SUPPORT EMAIL before publishing]_

> **To publish:** fill the date + contact email above, then host this page at a public URL
> (e.g. GitHub Pages) and paste that URL into App Store Connect, Google Play Console, and the
> in-app About/Privacy row. Both stores require a reachable privacy-policy URL before review.

## The short version

Quenderin runs entirely **on your device**. It has **no account, no servers, and no analytics**.
We — the developers — **do not collect, receive, store, or have access to any of your data.**

## What data we collect

**None.** Quenderin has no backend. There is no sign-up, no login, no telemetry, no crash
reporting, no advertising, and no third-party analytics or tracking SDKs. Your conversations and
any settings stay in the app's private storage on your device and are never transmitted to us or
to anyone else.

## The only network connection

Quenderin **does not use, integrate, or send data to any third-party AI service** — inference is
performed by the open-source llama.cpp engine compiled into the app itself. The app's only network
activity is fetching model files:

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

After a download, all AI inference happens offline on your device; you can use the app with no
network connection at all.

## Data stored on your device

- **Conversations** and app settings are stored locally in the app's private container.
- **Downloaded models** are stored locally (they can be several gigabytes).
- You can delete any of this at any time from within the app, or by deleting the app — there is
  nothing stored anywhere else to delete.

## AI-generated content

Responses are produced by an open-source language model running locally on your device. Output is
**not curated or filtered by us** and may be inaccurate, offensive, or otherwise objectionable.
Do not rely on it for professional, legal, medical, or financial advice.

## Children

Quenderin is not directed at children. Because it can generate unrestricted AI text, it is rated
for ages 17+.

## Changes to this policy

If this policy changes, the "Last updated" date above will change. Continued use after an update
means you accept the revised policy.

## Contact

Questions about this policy: [FILL SUPPORT EMAIL].
