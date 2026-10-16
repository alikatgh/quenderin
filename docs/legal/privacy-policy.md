# Quenderin — Privacy Policy

_Last updated: 2026-09-30_
_Contact: quenderin@aulenor.com_

> Public policy: https://quenderin.org/privacy. Keep this source and the hosted policy consistent.

## The short version

Quenderin runs AI inference entirely **on your device**. It has **no account or analytics**.
Your conversations, files and device settings stay on your device.

## What data we collect

There is no sign-up, no login, no telemetry, no crash
reporting, no advertising, and no third-party analytics or tracking SDKs. Your conversations and
any settings stay in the app's private storage on your device and are never transmitted to us or
to anyone else.

## Model discovery and download requests

Quenderin **does not use, integrate, or send data to any third-party AI service** — inference is
performed by the open-source llama.cpp engine compiled into the app itself. Model discovery and
downloads use these network requests:

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

Questions about this policy: quenderin@aulenor.com.
