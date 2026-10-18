#!/usr/bin/env node
// verify_no_secrets.mjs — refuse to publish or commit credentials.
//
// Two jobs, one file, copied into every project that deploys or holds keys:
//   node scripts/verify_no_secrets.mjs dist     scan a publish directory
//   node scripts/verify_no_secrets.mjs --staged scan staged files (pre-commit)
//   node scripts/verify_no_secrets.mjs --all    scan tracked files (CI)
//
// Cloudflare/Vercel serve every file in a publish directory, dotfiles
// included, so a stray .env becomes public. This fails the build instead.
import { execFileSync } from "node:child_process";
import { readFileSync, statSync, readdirSync, existsSync } from "node:fs";
import { join, extname, resolve, relative, isAbsolute, basename } from "node:path";

const args = process.argv.slice(2);
const MODE = args.includes("--staged") ? "staged" : args.includes("--all") ? "all" : "dir";
const DIR_ARG = args.find((a) => !a.startsWith("--")) || "dist";

const REPO = (() => {
  try { return execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim(); }
  catch { return process.cwd(); }
})();

const PATTERNS = {
  google_api_key: /AIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])/,
  openai_key: /\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{32,}/,
  github_token: /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b|\bgithub_pat_[A-Za-z0-9_]{30,}\b/,
  aws_access_key: /\bAKIA[0-9A-Z]{16}\b/,
  slack_token: /\bxox[baprs]-[A-Za-z0-9-]{10,}/,
  huggingface_token: /\bhf_[A-Za-z0-9]{30,}\b/,
  private_key: /-----BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----/,
};
const TEMPLATE = /\.(example|sample|template|schema)$/;
const BLOCKED_NAME = /(^|\/)\.env($|\.)|(^|\/)secrets?\.(json|ya?ml)$|\.pem$|\.key$|(^|\/)id_rsa($|\.)/i;
const SKIP_EXT = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".ico", ".pdf",
  ".zip", ".gz", ".woff", ".woff2", ".ttf", ".otf", ".mp4", ".webm", ".mp3", ".lock"]);
const MAX = 2_000_000;
const findings = [];

// Per-repo path allowlist for files whose key-shaped strings are public by
// design (Firebase client configs). Blocked filenames are never exempt.
const ALLOWLIST = (() => {
  const p = join(REPO, ".secret-scan-allow");
  if (!existsSync(p)) return [];
  return readFileSync(p, "utf8").split("\n")
    .map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
})();
const pathAllowed = (rel) => {
  const norm = rel.replace(/\\/g, "/");
  return ALLOWLIST.some((a) => norm === a || norm.startsWith(a.replace(/\/$/, "") + "/"));
};

function flagName(rel) {
  if (TEMPLATE.test(rel)) return false;
  return BLOCKED_NAME.test(rel.replace(/\\/g, "/"));
}

function scanFile(abs, rel) {
  let st;
  try { st = statSync(abs); } catch { return; }
  if (!st.isFile()) return;
  if (flagName(rel)) { findings.push(`${rel}  [blocked filename]`); return; }
  if (pathAllowed(rel)) return;
  if (SKIP_EXT.has(extname(rel).toLowerCase()) || st.size > MAX) return;
  let text;
  try { text = readFileSync(abs, "utf8"); } catch { return; }
  if (text.includes("\0")) return;
  const lines = text.split("\n");
  for (const [name, rx] of Object.entries(PATTERNS)) {
    for (let i = 0; i < lines.length; i++) {
      if (rx.test(lines[i]) && !lines[i].includes("secret_scan:allow")) {
        findings.push(`${rel}:${i + 1}  [${name}]`);
      }
    }
  }
}

function walk(dir, base) {
  for (const entry of readdirSync(dir)) {
    const abs = join(dir, entry);
    let st;
    try { st = statSync(abs); } catch { continue; }
    if (st.isDirectory()) {
      if (entry === "node_modules" || entry === ".git") continue;
      walk(abs, base);
    } else {
      scanFile(abs, relative(base, abs));
    }
  }
}

let label;
if (MODE === "dir") {
  const target = isAbsolute(DIR_ARG) ? DIR_ARG : resolve(REPO, DIR_ARG);
  try {
    if (statSync(target).isDirectory()) walk(target, target);
  } catch { console.error(`secret check: ${target} does not exist`); process.exit(1); }
  label = target;
} else {
  const gitArgs = MODE === "staged"
    ? ["diff", "--cached", "--name-only", "--diff-filter=ACM", "-z"]
    : ["ls-files", "-z"];
  const listed = execFileSync("git", gitArgs, { cwd: REPO, encoding: "utf8" }).split("\0").filter(Boolean);
  for (const rel of listed) scanFile(resolve(REPO, rel), rel);
  label = MODE === "staged" ? "staged files" : "tracked files";
}

if (findings.length) {
  console.error(`\nSECRET CHECK FAILED — ${label}:`);
  for (const f of findings) console.error("  ✗ " + f);
  console.error("\nRemove the file/value. Never commit or publish dotfiles or credentials.");
  process.exit(1);
}
console.log(`secret check: clean (${label})`);
