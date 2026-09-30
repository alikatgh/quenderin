# Model catalog freshness

The marketing site used a manually copied eight-model list. The app source has 13
models; the website tables, RAM calculator and structured data now come from the
same `shared/model-catalog.json` manifest. `src/constants.ts` remains the existing
authoritative app catalog, with parity checks across Apple and Android.

## What visitors see

- **Latest releases:** live original-model releases from recognized authors, with
  a standalone GGUF, verified file size/hash, model-card link and release date.
  Download-size filters help people explore compact models. They do not claim RAM fit.
- **Curated choices:** every model in the source app catalog, use case, download,
  estimated RAM and quantization. Catalog availability depends on installed app version.
- **Starting point:** a desktop RAM estimate using the app's RAM bands and memory
  headroom. iPhone selection remains chip/jetsam/storage aware inside the app.

The new-release feed never promotes a file to an app default automatically. A new
model can have an unsupported architecture, chat template, license or unacceptable
latency even when its quantization fits. “Best” is a device/task judgment; file
popularity and recency cannot establish it. Evaluate those before changing defaults.

## Automatic refresh

`workers/site.mjs` serves `/api/model-releases`; other requests use the static assets
binding. `workers/model-releases.mjs` reads public Hugging Face API metadata:

1. Recognized quant publishers: Unsloth, Qwen, bartowski and ggml-org. Original
   models must identify a recognized developer in `base_model` metadata.
2. Text/chat candidates only; no embeddings, image generators, split weights,
   projectors, imatrix files or speculative MTP sidecars.
3. Deduplicate original models, preserve compact choices, read original release
   dates (a new quant of an old model is not a new model), and verify GGUF metadata.
4. Up to 20 candidates, six list requests plus two metadata requests each: at most
   46 upstream requests, six-second timeouts, no weights downloaded. Standalone
   Q4 variants of 0.2–24 GB are eligible; this is bounded discovery, not all HF models.
5. Cache successful metadata for one hour. Keep the last success for up to a week;
   when refresh fails, show it as **Saved snapshot**, with its original checked time.
   A cold failure uses the committed `website/data/model-releases.json` snapshot.

The feed refreshes on the first visit after cache expiry. Upstream fetches also use
Cloudflare's one-hour cache. No cron, secret, new database or store update is required.
Only the website uses the feed; offline apps continue using their embedded catalog.
Only fixed public API URLs are requested: no visitor cookies, headers, identifiers,
conversations or user-selected URLs are forwarded. User-supplied query parameters
cannot select upstream destinations or create arbitrary cache keys.

## Updating curated recommendations

Verify engine/chat-template compatibility, pinned SHA-256, license, first-token
latency, decode speed, memory, cancellation and offline behavior on target devices.
Then update the three existing app catalogs and regenerate:

```sh
python3 scripts/export_catalog.py
python3 scripts/check_catalog_parity.py
python3 scripts/generate_features_models.py
npm run gen:website-catalog
npm run check:website-catalog
npm run test:website-catalog
```

Refresh the static fallback when publishing:

```sh
npm run refresh:model-releases
npm run gen:website-catalog
npx wrangler deploy --config wrangler.site.jsonc
```

Wrangler runs catalog parity and generation before publishing. GitHub Pages can
display the saved snapshot; automatic live discovery belongs to quenderin.org's Worker.

References: [Hugging Face public API](https://huggingface.co/docs/hub/api),
[Cloudflare asset routing](https://developers.cloudflare.com/workers/static-assets/routing/worker-script/),
[Cloudflare cache](https://developers.cloudflare.com/workers/runtime-apis/cache/).
