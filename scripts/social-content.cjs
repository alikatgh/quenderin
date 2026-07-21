/**
 * Quenderin — Facebook content pool.
 *
 * Bespoke captions in the site's honest, no-hype voice, grouped by the three
 * pillars from docs/FACEBOOK_STRATEGY.md. gen-social-posts.cjs assigns dates
 * (Mon spotlight / Wed engineering / Fri reality) and emits the calendar.
 *
 * Each post: { id, caption, image, link }
 *   image — a PUBLIC url the Graph API can fetch (served from quenderin.org).
 *   link  — dropped as the FIRST COMMENT (FB throttles in-caption links).
 *
 * Rules (carried from the site): no fake claims, every screenshot is real,
 * a small local model is honestly described as sometimes wrong.
 */

const SITE = 'https://quenderin.org';
const IMG = (p) => `${SITE}/assets/app/${p}`;
const SOCIAL = (p) => `${SITE}/assets/social/${p}`;

// UTM only on our own web/GitHub links; store links stay clean.
const utm = (url, campaign) =>
  `${url}${url.includes('?') ? '&' : '?'}utm_source=facebook&utm_medium=social&utm_campaign=${campaign}`;

const APPSTORE = 'https://apps.apple.com/app/id6789854363';
const GH = 'https://github.com/alikatgh/quenderin';
const BETA_GROUP = 'https://groups.google.com/g/quenderin-testers';
const BETA_OPTIN = 'https://play.google.com/apps/testing/ai.quenderin.app';

/* ---------------------------------------------------------------------- */
/* MONDAY — model & feature spotlight (the anchor). Screenshot = the ad.   */
/* ---------------------------------------------------------------------- */
const spotlight = [
  {
    id: 'ios-launch',
    caption:
      `Quenderin is on the App Store.\n\n` +
      `A real AI model, running fully on your iPhone — no account, no cloud, ` +
      `nothing leaves the device. Pick a model that fits your phone, download it ` +
      `once, and it works offline: on a plane, in a tunnel, anywhere.\n\n` +
      `Free. Open source. Every line on GitHub.`,
    image: IMG('chat.png'),
    link: APPSTORE,
  },
  {
    id: 'offline-proof',
    caption:
      `This reply was generated with the network off.\n\n` +
      `No request left the phone — the model is on the device, not a thin client ` +
      `for someone else's datacenter. 15 tokens/sec on an iPhone 12, measured. ` +
      `The whole point: nothing you type ever travels.`,
    image: IMG('phone-chat.png'),
    link: APPSTORE,
  },
  {
    id: 'model-picker',
    caption:
      `The app checks your hardware before it offers you anything.\n\n` +
      `RAM, chip, memory budget — then every model is labelled Fits, Tight, or ` +
      `Too big, with the real numbers. It won't hand you a model that would run ` +
      `out of memory. An honest default you can always override.`,
    image: IMG('picker.png'),
    link: utm(`${SITE}/blog-setup.html`, 'spotlight'),
  },
  {
    id: 'agent-macos',
    caption:
      `On a Mac, Quenderin can do the task — not just answer it.\n\n` +
      `The computer-use agent works with your files, apps, and Apple Shortcuts, ` +
      `and it shows its work: every tool call in the run log. By design it can ` +
      `never touch payments, deletion, or credentials.`,
    image: IMG('agent.png'),
    link: utm(`${SITE}/blog-computer-use.html`, 'spotlight'),
  },
  {
    id: 'plain-language-profile',
    caption:
      `Every model, explained in plain language.\n\n` +
      `Parameters, download size, memory, quantization — with a glossary behind ` +
      `one button, no jargon assumed. You should know exactly what you're putting ` +
      `on your device before you download 4 GB of it.`,
    image: IMG('profile.png'),
    link: APPSTORE,
  },
  {
    id: 'ultra-light',
    caption:
      `Not a new phone? Still runs.\n\n` +
      `The ultra-light build is a 0.4 GB download that runs on modest hardware. ` +
      `Bigger phone, bigger model — your choice, from 0.4 GB up to a ~13 GB ` +
      `mixture-of-experts flagship. The picker tells you honestly what fits.`,
    image: IMG('welcome.png'),
    link: APPSTORE,
  },
  {
    id: 'catalog',
    caption:
      `Llama, Qwen, Gemma — your pick, running locally.\n\n` +
      `A curated catalog of open models, each with a plain quality grade and a ` +
      `real download size. Same one-tap install, same offline result. You choose ` +
      `the trade between size and capability.`,
    image: IMG('picker.png'),
    link: APPSTORE,
  },
  {
    id: 'agent-runlog',
    caption:
      `An agent that shows its work.\n\n` +
      `Every tool call is in the run log — the unit converter, the calculator, ` +
      `the steps it took to the answer. No black box. And a hard architectural ` +
      `line it cannot cross: payments, deletion, credentials are off-limits.`,
    image: IMG('agent.png'),
    link: utm(`${SITE}/blog-agent-hands.html`, 'spotlight'),
  },
  {
    id: 'android-beta',
    caption:
      `Quenderin on Android — the closed beta is open.\n\n` +
      `Same local-inference core as the iPhone app, rebuilt native for Android. ` +
      `Two steps to get in: join the testers group, then opt in on Google Play. ` +
      `It's an early build — your feedback shapes what ships.`,
    image: IMG('chat.png'),
    link: BETA_GROUP,
  },
  {
    id: 'cli',
    caption:
      `Prefer a terminal? Quenderin has one.\n\n` +
      `The same local model, driven from the command line on your desktop — ` +
      `scriptable, offline, open source. The terminal gets a seat at the table.`,
    image: IMG('chat.png'),
    link: utm(`${SITE}/blog-cli.html`, 'spotlight'),
  },
  {
    id: 'desktop',
    caption:
      `Run it on your laptop today.\n\n` +
      `The desktop app is open source and runs from GitHub on macOS and Linux — ` +
      `the same probe-download-offline flow, the same models. Four lines to clone ` +
      `and go.`,
    image: IMG('picker.png'),
    link: utm(GH, 'spotlight'),
  },
  {
    id: 'resumable-download',
    caption:
      `Lose Wi-Fi at 80%? It picks up where it left off.\n\n` +
      `The model download is resumable and Wi-Fi-only by default, so a multi-GB ` +
      `pull never surprises your cellular bill. Small details, because first-run ` +
      `is the one part that isn't instant.`,
    image: IMG('welcome.png'),
    link: APPSTORE,
  },
  {
    id: 'model-router',
    caption:
      `Hit a hard question? It can reach for a bigger model.\n\n` +
      `If you've installed more than one, the router can suggest a larger model ` +
      `for a task the small one will struggle with — you stay in control, and it ` +
      `stays on-device. Right-sized by default, upgradable on demand.`,
    image: IMG('profile.png'),
    link: APPSTORE,
  },
  {
    id: 'model-search',
    caption:
      `Want a model that isn't in the catalog? Search for it.\n\n` +
      `On iPhone you can search open models on Hugging Face, and Quenderin ` +
      `installs them through the same integrity-checked path as the curated ones ` +
      `— same magic-header and checksum gate, same offline result.`,
    image: IMG('picker.png'),
    link: APPSTORE,
  },
  {
    id: 'quality-grades',
    caption:
      `Every model in the app wears its honesty on its sleeve.\n\n` +
      `A plain-language quality grade sits right next to each one, so you're never ` +
      `guessing whether the tiny fast model is up to your task. Pick with your ` +
      `eyes open — that's the whole idea.`,
    image: IMG('profile.png'),
    link: utm(`${SITE}/reality.html`, 'spotlight'),
  },
];

/* ---------------------------------------------------------------------- */
/* WEDNESDAY — behind the engineering. Mirror the blog. Honest war stories.*/
/* ---------------------------------------------------------------------- */
const engineering = [
  {
    id: 'ggml-abort',
    caption:
      `The crash that only happened after you'd used the app.\n\n` +
      `⌘Q → SIGABRT — but only if you'd sent one message first. Eleven ` +
      `byte-identical crash reports in a day. The culprit: llama.cpp's Metal ` +
      `backend asserting inside C++ static destructors at process exit. The fix ` +
      `is one line, and the underscore in _exit(0) is load-bearing.`,
    image: IMG('phone-chat.png'),
    link: utm(`${SITE}/blog-ggml-abort.html`, 'engineering'),
  },
  {
    id: 'model-integrity',
    caption:
      `Never trust a model file until it's verified.\n\n` +
      `A model is multi-gigabyte untrusted bytes going into a native C++ parser — ` +
      `textbook attack surface. So there's a hard gate: HTTP status before the ` +
      `first byte, GGUF magic, SHA-256. An App Store reviewer found the one hole ` +
      `we'd missed. Here's the whole story.`,
    image: IMG('picker.png'),
    link: utm(`${SITE}/blog-model-integrity.html`, 'engineering'),
  },
  {
    id: 'setup-probe',
    caption:
      `How the app guesses what your device can run — and admits it's a guess.\n\n` +
      `It reads your RAM, chip, and (on a phone) the memory budget iOS will grant ` +
      `before it kills the app, then picks the largest model that clears a fitness ` +
      `gate. Total RAM isn't free RAM, so it's honest about the heuristic.`,
    image: IMG('picker.png'),
    link: utm(`${SITE}/blog-setup.html`, 'engineering'),
  },
  {
    id: 'computer-use',
    caption:
      `A computer-use agent that never leaves your Mac.\n\n` +
      `It can operate your machine — but it's local, it logs every action to an ` +
      `on-disk ledger, and undo works even in a new session. Safety as an ` +
      `architectural property, not a promise about model behaviour.`,
    image: IMG('agent.png'),
    link: utm(`${SITE}/blog-computer-use.html`, 'engineering'),
  },
  {
    id: 'twin-parity',
    caption:
      `iOS and Android don't share a codebase — so how do they stay identical?\n\n` +
      `The core logic (memory-fitness math, model catalog, download-integrity ` +
      `gate) is hand-ported between Swift and Kotlin. A parity harness makes both ` +
      `platforms produce byte-identical answers for a shared set of test vectors, ` +
      `checked on every commit. It's caught real drift more than once.`,
    image: IMG('chat.png'),
    link: utm(`${SITE}/blog-android-beta.html`, 'engineering'),
  },
  {
    id: 'appstore-rejection',
    caption:
      `Apple rejected a build for "an error on model download." They were right.\n\n` +
      `One catalog entry pointed at a repo that had been renamed — the URL 404'd, ` +
      `and the downloader wrote the error page to disk before checking the status ` +
      `code. Three fixes, plus a CI job that pings every model URL so it can't ` +
      `recur. The honesty: we ship the post-mortem.`,
    image: IMG('picker.png'),
    link: utm(`${SITE}/blog-model-integrity.html`, 'engineering'),
  },
  {
    id: 'agent-hands',
    caption:
      `The agent grows hands — locally.\n\n` +
      `Tool use, running on-device: the model can call a calculator, a converter, ` +
      `and more, and it shows each call. The interesting part is the guardrail — ` +
      `whole categories of action are impossible by construction, not by asking ` +
      `the model nicely.`,
    image: IMG('agent.png'),
    link: utm(`${SITE}/blog-agent-hands.html`, 'engineering'),
  },
  {
    id: 'exit-hard',
    caption:
      `Why the Mac app exits with _exit(0) instead of a graceful shutdown.\n\n` +
      `Because there's nothing to lose at exit: every conversation turn and agent ` +
      `action is persisted continuously, not on quit. So we can skip the C++ ` +
      `teardown that was aborting — it loses nothing and removes the one broken ` +
      `thing in it. Designing around a library that aborts instead of returning.`,
    image: IMG('phone-chat.png'),
    link: utm(`${SITE}/blog-ggml-abort.html`, 'engineering'),
  },
  {
    id: 'streaming-sha',
    caption:
      `How do you verify a 13 GB model without 13 GB of RAM?\n\n` +
      `You stream it through the hasher a megabyte at a time, so checking a huge ` +
      `model costs kilobytes, not gigabytes. And the file is written to a ` +
      `.partial path, only renamed into place after it verifies — so no consumer ` +
      `can ever pick a half-written model.`,
    image: IMG('picker.png'),
    link: utm(`${SITE}/blog-model-integrity.html`, 'engineering'),
  },
  {
    id: 'jetsam-probe',
    caption:
      `The number that decides what model your iPhone can run isn't "total RAM."\n\n` +
      `It's the jetsam budget — how much memory iOS lets one app hold before it ` +
      `kills it — plus an overhead factor for the KV cache inference needs at ` +
      `runtime. The probe is deliberately pessimistic on phones: better to ` +
      `under-pick than to crash.`,
    image: IMG('picker.png'),
    link: utm(`${SITE}/blog-setup.html`, 'engineering'),
  },
  {
    id: 'disk-preflight',
    caption:
      `A download that can't finish shouldn't start.\n\n` +
      `Before pulling a multi-GB model, Quenderin does a disk-space preflight and ` +
      `refuses if it won't fit — because running out of space at 90% is a worse ` +
      `experience than a clear "no" up front. Boring engineering. It's most of the ` +
      `job.`,
    image: IMG('welcome.png'),
    link: utm(`${SITE}/blog-setup.html`, 'engineering'),
  },
  {
    id: 'moe-flagship',
    caption:
      `Dense-model RAM math is wrong for mixture-of-experts — so we fixed the math.\n\n` +
      `A paged MoE flagship can be far larger on disk than the RAM it actually ` +
      `needs to run, because only a few experts are active per token. Getting the ` +
      `fitness heuristic right for MoE is what lets a big model run on hardware ` +
      `that "shouldn't" fit it.`,
    image: IMG('profile.png'),
    link: utm(`${SITE}/reality.html`, 'engineering'),
  },
  {
    id: 'ci-liveness',
    caption:
      `Cross-platform parity proved the twins agreed. It didn't prove the URL was alive.\n\n` +
      `All four platforms agreeing on the same dead model link still ships a dead ` +
      `link. So now a CI job does a one-byte ranged GET against every catalog URL ` +
      `on a schedule — rot gets caught by us, before your multi-GB download 404s.`,
    image: IMG('picker.png'),
    link: utm(`${SITE}/blog-model-integrity.html`, 'engineering'),
  },
];

/* ---------------------------------------------------------------------- */
/* FRIDAY — honest reality / privacy / community. Carries the values.      */
/* ---------------------------------------------------------------------- */
const reality = [
  {
    id: 'sometimes-wrong',
    caption:
      `A model that fits on your phone is smaller than one in a datacenter — and ` +
      `it will sometimes be confidently wrong.\n\n` +
      `We don't hide that. Every model carries a plain quality grade, the empty ` +
      `state warns you before you start, and we publish the real numbers instead ` +
      `of adjectives. That's the trade: a slice of raw capability, for the network ` +
      `never being in the loop.`,
    image: IMG('profile.png'),
    link: utm(`${SITE}/reality.html`, 'reality'),
  },
  {
    id: 'real-numbers',
    caption:
      `We publish exactly how much smaller a local model is.\n\n` +
      `Not adjectives — measured numbers: tokens/sec on real devices, download ` +
      `sizes, memory. If we're going to ask you to trust the private part, you ` +
      `should be able to check the honest part.`,
    image: IMG('profile.png'),
    link: utm(`${SITE}/reality.html`, 'reality'),
  },
  {
    id: 'no-account',
    caption:
      `No account. No email. No telemetry. Just the code.\n\n` +
      `There's no sign-up because there's no server to sign up to. After the ` +
      `one-time model download, an offline-readiness check confirms zero network ` +
      `calls. Don't take our word for it — it's MIT, read it.`,
    image: IMG('welcome.png'),
    link: utm(GH, 'reality'),
  },
  {
    id: 'works-anywhere',
    caption:
      `Airplane mode is not a limitation here. It's the point.\n\n` +
      `On a plane, in a tunnel, in a tent, on a dead-zone commute — the model is ` +
      `already on your device. Nothing to reach, nothing to wait for.`,
    image: IMG('phone-chat.png'),
    link: APPSTORE,
  },
  {
    id: 'what-model-next',
    caption:
      `What model should we add next?\n\n` +
      `The catalog is curated for models that actually run well on-device — but ` +
      `we're always looking. Drop the model you want to run locally in the ` +
      `comments, and why.`,
    image: IMG('picker.png'),
    link: utm(GH, 'reality'),
  },
  {
    id: 'open-core',
    caption:
      `Free, and every line is public.\n\n` +
      `Quenderin is open source under the MIT licence — the probe, the integrity ` +
      `gate, the inference engine, all of it. You can read exactly what runs on ` +
      `your device, and run it yourself from source.`,
    image: IMG('chat.png'),
    link: utm(GH, 'reality'),
  },
  {
    id: 'you-own-it',
    caption:
      `After the download, the model is a file on your disk.\n\n` +
      `Not a subscription, not a session that expires, not something that can be ` +
      `deprecated out from under you. You downloaded it; it's yours; it runs with ` +
      `no permission from anyone.`,
    image: IMG('profile.png'),
    link: APPSTORE,
  },
  {
    id: 'thermal-honesty',
    caption:
      `The honest cost of running a model on your phone.\n\n` +
      `Sustained generation warms the chip and uses battery, and the context ` +
      `window is smaller than a server's. We'd rather you know the trade-offs up ` +
      `front than discover them mid-task. Private-by-necessity is worth it — but ` +
      `only you can decide that.`,
    image: IMG('phone-chat.png'),
    link: utm(`${SITE}/reality.html`, 'reality'),
  },
  {
    id: 'beta-help',
    caption:
      `Help push the Android app to the finish line.\n\n` +
      `Google graduates a closed beta once 12 testers have stayed engaged for 14 ` +
      `days. If you've got an Android phone and a few minutes across two weeks, ` +
      `join the testers group and opt in — that's the whole favour.`,
    image: IMG('chat.png'),
    link: BETA_OPTIN,
  },
  {
    id: 'why-local',
    caption:
      `Why run an AI locally at all?\n\n` +
      `Because "it works offline" and "nothing leaves the device" turn out to be ` +
      `the same feature. Private by necessity, available by necessity. For anyone ` +
      `offline, privacy-bound, or just done being metered — that's the entire ` +
      `reason to be here.`,
    image: IMG('welcome.png'),
    link: utm(SITE, 'reality'),
  },
  {
    id: 'read-the-code',
    caption:
      `"Trust us" is not a security model. The source is.\n\n` +
      `Everything that decides what runs on your device — and proves nothing ` +
      `leaves it — is open. Star the repo if you want to follow along, or clone ` +
      `it and check for yourself.`,
    image: IMG('agent.png'),
    link: utm(GH, 'reality'),
  },
  {
    id: 'verifiable-offline',
    caption:
      `"Nothing leaves your device" is a claim you can check.\n\n` +
      `Turn on airplane mode and the app still works — because there was never a ` +
      `network call to lose. Zero calls after the one-time model download, and an ` +
      `offline-readiness check that confirms it before you leave signal.`,
    image: IMG('phone-chat.png'),
    link: utm(`${SITE}/reality.html`, 'reality'),
  },
  {
    id: 'roadmap',
    caption:
      `Where Quenderin is going, stage by stage.\n\n` +
      `iPhone shipped, Android in beta, desktop from source — and the roadmap is ` +
      `public. Local autonomous computer use is the real mission; the private ` +
      `offline chat is the foundation. Read the plan, tell us what's missing.`,
    image: IMG('agent.png'),
    link: utm(`${SITE}/roadmap.html`, 'reality'),
  },
  {
    id: 'context-honesty',
    caption:
      `Straight talk: an on-device model has a smaller context window than a ` +
      `server's.\n\n` +
      `It can't hold as much of a long document or conversation at once. That's a ` +
      `real limit of running locally, and we'd rather name it than let you hit it ` +
      `by surprise. In exchange, the whole thing runs in your hand, offline.`,
    image: IMG('chat.png'),
    link: utm(`${SITE}/reality.html`, 'reality'),
  },
  {
    id: 'thanks-milestone',
    caption:
      `A quiet thank-you.\n\n` +
      `Quenderin went from "runs on my machine" to on the App Store and into ` +
      `Android beta — built in the open, by people who read the stack traces. If ` +
      `it's useful to you, a star on GitHub or a share is how it finds the next ` +
      `person who needs an AI that never phones home.`,
    image: IMG('welcome.png'),
    link: utm(GH, 'reality'),
  },
];

module.exports = { spotlight, engineering, reality };
