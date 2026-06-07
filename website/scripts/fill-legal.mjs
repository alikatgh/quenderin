#!/usr/bin/env node
// Single-source legal/operator detail injector for the marketing site.
//
// Reads website/site.config.json and replaces the `<span class="ph">[…]</span>`
// placeholders in the legal pages with the configured values. A placeholder whose
// config value is still blank is left in place and reported — so this is safe to
// run repeatedly as you fill the config in.
//
//   node website/scripts/fill-legal.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const cfg = JSON.parse(readFileSync(join(root, "site.config.json"), "utf8"));

// Each placeholder (exact on-page HTML) → the site.config.json key that fills it.
const MAP = [
  ["legal.html",   '<span class="ph">[LEGAL NAME OR COMPANY]</span>',                                  "legalName"],
  ["legal.html",   '<span class="ph">[STREET, POSTAL CODE, CITY, COUNTRY]</span>',                       "address"],
  ["legal.html",   '<span class="ph">[PHONE, if required in your country]</span>',                        "phone"],
  ["legal.html",   '<span class="ph">[NAME &amp; ADDRESS of the person responsible]</span>',              "responsibleParty"],
  ["terms.html",   '<span class="ph">[trademarks / property of OPERATOR]</span>',                         "trademarkOwner"],
  ["terms.html",   '<span class="ph">[JURISDICTION]</span>',                                              "jurisdiction"],
  ["privacy.html", '<span class="ph">[LEGAL NAME / ENTITY]</span>',                                       "legalName"],
  ["privacy.html", '<span class="ph">[POSTAL ADDRESS]</span>',                                            "address"],
  ["privacy.html", '<span class="ph">[FORM PROVIDER, e.g. Formspree, Inc. — or remove if unused]</span>', "formProvider"],
];

const escapeHtml = (s) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const files = {};
let filled = 0;
const remaining = new Set();

for (const [file, find, key] of MAP) {
  files[file] ??= readFileSync(join(root, file), "utf8");
  const value = String(cfg[key] ?? "").trim();
  if (!value) { remaining.add(key); continue; }
  if (files[file].includes(find)) {
    files[file] = files[file].split(find).join(escapeHtml(value));
    filled++;
  }
}

for (const [file, html] of Object.entries(files)) writeFileSync(join(root, file), html);

console.log(`fill-legal: injected ${filled} placeholder occurrence(s).`);
if (remaining.size) {
  console.log(`Still blank in site.config.json — fill these and re-run: ${[...remaining].sort().join(", ")}`);
} else {
  console.log("All legal placeholders are filled. Ready to publish.");
}
