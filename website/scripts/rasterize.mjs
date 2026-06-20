#!/usr/bin/env node
// Rasterize the brand SVGs into the PNGs that real-world consumers require but
// SVG can't satisfy: social scrapers (Twitter/LinkedIn/Slack/iMessage) need a
// PNG/JPG og:image, and iOS apple-touch-icon must be PNG. Pure headless Chrome,
// no deps. Each asset is rendered from an exact-size HTML wrapper so output
// dimensions are deterministic.
//
// Built to catch: "social preview is blank" (SVG og:image silently unsupported)
// and "home-screen icon is missing/black" (no PNG touch icon).
// Usage:  node website/scripts/rasterize.mjs
// Writes: og-image.png, favicon-32.png, favicon-16.png, apple-touch-icon.png

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = dirname(HERE);
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const tmp = mkdtempSync(join(tmpdir(), "qraster-"));

const ogSvg = readFileSync(join(WEB, "og-image.svg"), "utf8");
const favSvg = readFileSync(join(WEB, "favicon.svg"), "utf8");

// [outfile, width, height, scale, background, svg, extraCss]
const JOBS = [
  ["og-image.png", 1200, 630, 1, "#ffffff", ogSvg, ""],
  ["favicon-32.png", 32, 32, 1, "transparent", favSvg, ""],
  ["favicon-16.png", 16, 16, 1, "transparent", favSvg, ""],
  // iOS masks the corners itself; a solid brand fill avoids black fringing.
  ["apple-touch-icon.png", 180, 180, 1, "#635BFF", favSvg, "svg{border-radius:0}"],
];

function wrapper(w, h, bg, svg, css) {
  const sized = svg.replace(
    /<svg /,
    `<svg width="${w}" height="${h}" preserveAspectRatio="xMidYMid meet" `
  );
  return `<!doctype html><meta charset="utf-8"><style>
    html,body{margin:0;padding:0}
    body{width:${w}px;height:${h}px;background:${bg};overflow:hidden}
    svg{display:block;width:${w}px;height:${h}px}${css}
  </style>${sized}`;
}

let ok = 0;
for (const [out, w, h, scale, bg, svg, css] of JOBS) {
  const htmlPath = join(tmp, out + ".html");
  writeFileSync(htmlPath, wrapper(w, h, bg, svg, css));
  const r = spawnSync(CHROME, [
    "--headless=new",
    "--hide-scrollbars",
    `--force-device-scale-factor=${scale}`,
    `--window-size=${w},${h}`,
    bg === "transparent" ? "--default-background-color=00000000" : "",
    `--screenshot=${join(WEB, out)}`,
    "file://" + htmlPath,
  ].filter(Boolean), { stdio: "ignore" });
  console.log(`  ${r.status === 0 ? "✓" : "✗"} ${out} (${w}×${h})`);
  if (r.status === 0) ok++;
}
console.log(`rasterized ${ok}/${JOBS.length}`);
process.exit(ok === JOBS.length ? 0 : 1);
