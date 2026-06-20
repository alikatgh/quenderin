#!/usr/bin/env node
// Full-page / per-section screenshotter for the marketing site, via the Chrome
// DevTools Protocol (no puppeteer dependency — uses Node's global WebSocket).
//
// Built to catch: headless `--screenshot` fires before scroll-reveal
// (IntersectionObserver) triggers, so below-fold sections capture BLANK. This
// forces `.reveal` visible, sets the theme, lets the gradient canvas paint,
// then uses captureBeyondViewport to grab any region without scrolling.
//
// Usage:
//   node website/scripts/shoot.mjs <url> <outDir> [theme=light|dark] [width=1440]
// Captures: 00-full.png (whole page) + one PNG per <section id> / hero / footer.
//
// Does NOT catch: real interaction (hover/click states), cross-browser quirks.

import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";

const URL = process.argv[2] || "http://127.0.0.1:8099/";
const OUT = process.argv[3] || "/tmp/qshots";
const THEME = process.argv[4] || "light";
const WIDTH = Number(process.argv[5] || 1440);
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PORT = 9333;

mkdirSync(OUT, { recursive: true });

const chrome = spawn(CHROME, [
  "--headless=new",
  `--remote-debugging-port=${PORT}`,
  "--user-data-dir=/tmp/qshoot-profile",
  "--hide-scrollbars",
  "--force-device-scale-factor=2",
  `--window-size=${WIDTH},1000`,
  "--no-first-run",
  URL,
], { stdio: "ignore" });

process.on("exit", () => chrome.kill());

// Wait for the debugger endpoint, then grab the page target's ws URL.
async function targetWs() {
  for (let i = 0; i < 50; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/json`);
      const tabs = await r.json();
      const page = tabs.find((t) => t.type === "page" && t.webSocketDebuggerUrl);
      if (page) return page.webSocketDebuggerUrl;
    } catch {}
    await sleep(100);
  }
  throw new Error("CDP endpoint never came up");
}

let _id = 0;
function rpc(ws, method, params = {}) {
  const id = ++_id;
  return new Promise((resolve, reject) => {
    const onMsg = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id === id) {
        ws.removeEventListener("message", onMsg);
        m.error ? reject(new Error(m.error.message)) : resolve(m.result);
      }
    };
    ws.addEventListener("message", onMsg);
    ws.send(JSON.stringify({ id, method, params }));
  });
}

const wsUrl = await targetWs();
const ws = new WebSocket(wsUrl);
await new Promise((res) => (ws.onopen = res));

await rpc(ws, "Page.enable");
await rpc(ws, "Runtime.enable");
// Reusing --user-data-dir means a warm disk cache would serve a stale page
// after edits. Force every fetch to hit the live server.
await rpc(ws, "Network.enable");
await rpc(ws, "Network.setCacheDisabled", { cacheDisabled: true });
await rpc(ws, "Emulation.setDeviceMetricsOverride", {
  width: WIDTH, height: 1000, deviceScaleFactor: 2, mobile: WIDTH < 600,
});

// Set theme BEFORE load settles, navigate fresh, wait for load event.
await rpc(ws, "Page.navigate", { url: URL });
await sleep(1800); // gradient canvas + fonts + reveal observers

// Force every reveal visible, pin the theme, and nudge scroll so any
// observer-based section animates in. Then measure the full page.
const dims = await rpc(ws, "Runtime.evaluate", {
  expression: `(() => {
    try { localStorage.setItem('quenderin_theme', '${THEME}'); } catch (e) {}
    document.documentElement.setAttribute('data-theme-mode', '${THEME}');
    const s = document.createElement('style');
    s.textContent = '.reveal{opacity:1!important;transform:none!important}';
    document.head.appendChild(s);
    window.scrollTo(0, document.body.scrollHeight);
    window.scrollTo(0, 0);
    const r = (sel) => { const el = document.querySelector(sel); if (!el) return null;
      const b = el.getBoundingClientRect(); const t = window.scrollY;
      return { y: Math.max(0, b.top + t), h: b.height }; };
    const sections = {};
    document.querySelectorAll('section[id], .hero, .site-footer, .cta-band').forEach((el, i) => {
      const id = el.id || el.className.split(' ')[0] || ('sec' + i);
      const b = el.getBoundingClientRect(); const t = window.scrollY;
      sections[id] = { y: Math.max(0, Math.round(b.top + t)), h: Math.round(b.height) };
    });
    return JSON.stringify({
      w: document.documentElement.scrollWidth,
      h: document.documentElement.scrollHeight,
      sections,
    });
  })()`,
  returnByValue: true,
});
const { w, h, sections } = JSON.parse(dims.result.value);
console.log(`page ${w}x${h}, sections: ${Object.keys(sections).join(", ")}`);

await sleep(600);

async function shoot(name, clip) {
  const res = await rpc(ws, "Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: true,
    clip: { ...clip, scale: 1 },
  });
  writeFileSync(`${OUT}/${name}.png`, Buffer.from(res.data, "base64"));
  console.log(`  wrote ${name}.png (${clip.width}x${Math.round(clip.height)})`);
}

// Whole page (capped height so the PNG stays sane).
await shoot(`00-full-${THEME}`, { x: 0, y: 0, width: w, height: Math.min(h, 20000) });

// Per section, readable.
let i = 1;
for (const [id, { y, h: sh }] of Object.entries(sections)) {
  if (sh < 40) continue;
  const n = String(i++).padStart(2, "0");
  await shoot(`${n}-${id}-${THEME}`, { x: 0, y, width: w, height: sh });
}

ws.close();
chrome.kill();
console.log("done");
process.exit(0);
