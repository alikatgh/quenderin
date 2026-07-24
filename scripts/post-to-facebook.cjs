#!/usr/bin/env node
/**
 * Publish the scheduled Quenderin post to the Facebook Page via the Meta Graph
 * API: post the screenshot as a photo with the caption, then drop the link
 * (App Store / GitHub / beta) as the FIRST COMMENT — Facebook ranks
 * link-in-comment above link-in-caption (see docs/FACEBOOK_STRATEGY.md).
 *
 * Reads docs/social/calendar.json (from gen-social-posts.cjs) and posts the
 * entry whose `date` == today (UTC), so a Mon/Wed/Fri cron just works.
 *
 * Flags:
 *   --date YYYY-MM-DD  force a specific calendar date (manual / testing)
 *   --dry-run          print what it WOULD post; call nothing
 *
 * Env (GitHub Actions secrets):
 *   FB_PAGE_ID     — the Page's numeric id
 *   FB_PAGE_TOKEN  — long-lived Page access token (pages_manage_posts scope)
 *   FB_AUTOPILOT_FROM — optional YYYY-MM-DD; skip any date before this (the
 *                       hand-scheduled Planner window, to avoid double-posting)
 *
 * Nothing posts without both secrets — safe to run in CI before they're set.
 */
const fs = require('fs');
const path = require('path');

const GRAPH = 'https://graph.facebook.com/v21.0';
const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const dateArg = (() => {
  const i = args.indexOf('--date');
  return i >= 0 ? args[i + 1] : null;
})();

const calendar = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'docs/social/calendar.json'), 'utf8'),
);

const today = new Date().toISOString().slice(0, 10);
const target = dateArg || today;

// The hand-scheduled Planner window fires via Facebook's own scheduler; the
// cron must not touch those dates or it double-posts.
const from = process.env.FB_AUTOPILOT_FROM;
const MANUAL_DONE = new Set(
  (process.env.FB_MANUAL_DONE || '').split(',').map((s) => s.trim()).filter(Boolean),
);
if (!dateArg) {
  if (from && target < from) {
    console.log(`Before autopilot start ${from} (hand-scheduled window). Nothing to do.`);
    process.exit(0);
  }
  if (MANUAL_DONE.has(target)) {
    console.log(`${target} was hand-scheduled in the Planner. Skipping to avoid a double-post.`);
    process.exit(0);
  }
}

const post = calendar.find((p) => p.date === target);
if (!post) {
  console.log(`No post scheduled for ${target}. Nothing to do.`);
  process.exit(0);
}

console.log(`→ ${post.date} (${post.day}) · ${post.pillar} · ${post.id}${post.rotated ? ' ↻' : ''}`);
if (post.rotated) {
  console.log('  NOTE: this is a rotated (repeat) entry — consider refreshing its angle.');
}

const TOKEN = process.env.FB_PAGE_TOKEN;

// Publish against `me`, not the numeric page id: a Page access token resolves
// `me` to its own Page. Posting to /{page-id}/photos with that token is
// rejected as "(#100) global id not allowed", so the token alone is enough.
const TARGET = 'me';

if (dryRun || !TOKEN) {
  console.log(dryRun ? '\n[dry-run] would post:\n' : '\n[no FB_PAGE_TOKEN — nothing sent]\n');
  console.log('caption:\n' + post.caption);
  console.log('\nimage:  ' + post.image);
  console.log('link (1st comment): ' + post.link);
  process.exit(0);
}

async function graph(url, body) {
  const res = await fetch(url, { method: 'POST', body });
  const json = await res.json();
  if (!res.ok || json.error) {
    throw new Error(`Graph API ${res.status}: ${JSON.stringify(json.error || json)}`);
  }
  return json;
}

(async () => {
  // 1) photo + caption
  const photoBody = new URLSearchParams({
    url: post.image,
    caption: post.caption,
    access_token: TOKEN,
  });
  const photo = await graph(`${GRAPH}/${TARGET}/photos`, photoBody);
  const storyId = photo.post_id || photo.id;
  console.log(`  posted photo → ${storyId}`);

  // 2) link as the first comment - best-effort. Commenting needs
  //    pages_manage_engagement (posting only needs pages_manage_posts); if the
  //    token lacks it, log the link and move on rather than fail after the post
  //    already published.
  if (post.link && storyId) {
    try {
      const commentBody = new URLSearchParams({ message: post.link, access_token: TOKEN });
      const comment = await graph(`${GRAPH}/${storyId}/comments`, commentBody);
      console.log(`  link comment → ${comment.id}`);
    } catch (e) {
      console.warn(`  note: could not add link comment (${e.message}). Post is up. ` +
        `Grant pages_manage_engagement to enable auto-comments. Link: ${post.link}`);
    }
  }
  console.log('  done.');
})().catch((err) => {
  console.error('FAILED:', err.message);
  process.exit(1);
});
