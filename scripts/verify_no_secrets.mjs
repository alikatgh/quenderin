#!/usr/bin/env node
// Fail closed before committing or publishing credentials. No dependency install:
//   node scripts/verify_no_secrets.mjs dist      scan a publish directory
//   node scripts/verify_no_secrets.mjs --staged  scan added/changed index blobs
//   node scripts/verify_no_secrets.mjs --all     scan tracked working-tree files
// This is a bounded pattern check, not proof that arbitrary content is secret-free.
import { execFileSync } from "node:child_process";
import { constants, closeSync, fstatSync, lstatSync, openSync, readSync, readdirSync, realpathSync } from "node:fs";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

const MAX_FILE_BYTES = 16 * 1024 * 1024;
const MAX_TOTAL_BYTES = 256 * 1024 * 1024;
const MAX_ENTRIES = 20_000;
const MAX_FINDINGS = 100;
const DEADLINE = Date.now() + 60_000;
const PATTERNS = {
  google_api_key: /AIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])/,
  openai_key: /\bsk-(?:proj-|svcacct-|ant-)?[A-Za-z0-9_-]{32,}/,
  github_token: /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b|\bgithub_pat_[A-Za-z0-9_]{30,}\b/,
  aws_access_key: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
  slack_token: /\b(?:xox[baprs]|xapp)-[A-Za-z0-9-]{10,}/,
  huggingface_token: /\bhf_[A-Za-z0-9]{30,}\b/,
  npm_token: /\bnpm_[A-Za-z0-9]{30,}\b/,
  stripe_key: /\b(?:sk|rk)_live_[A-Za-z0-9]{20,}\b/,
  private_key: /-----BEGIN (?:(?:RSA |OPENSSH |EC |DSA |ENCRYPTED )?PRIVATE KEY|PGP PRIVATE KEY BLOCK)-----/,
};
// Check every path component before any content read, including template files.
const BLOCKED_NAME = /^(?:\.env.*|secrets\..*|secret\.(?:json|ya?ml)|id_(?:rsa|dsa|ecdsa|ed25519)(?:\..*)?)$|\.(?:pem|key|p8|p12|pfx|pkcs12|jks|keystore|keychain|keychain-db|ppk|kdbx)$/i;
const BLOCKED_DIRECTORY = new Set([".git", ".hg", ".svn"]);
// Diagnostics redact conservatively even when surrounding filename characters
// prevent a content rule's word boundary or exact token-ending match.
const PATH_PATTERNS = Object.values(PATTERNS).map((pattern) => new RegExp(
  pattern.source.replaceAll("\\b", "").replaceAll("(?![0-9A-Za-z_-])", ""),
));
const findings = [];
let findingCount = 0;
let entryCount = 0;
let totalBytes = 0;

function displayPath(name) {
  // A malicious filename must not inject log lines or print a key-shaped value.
  if (PATH_PATTERNS.some((pattern) => pattern.test(name))) return '"[redacted filename]"';
  return JSON.stringify(name);
}

function flag(name, reason, line) {
  findingCount++;
  if (findings.length < MAX_FINDINGS) findings.push(`${displayPath(name)}${line ? `:${line}` : ""}  [${reason}]`);
}

function checkBudget() {
  if (Date.now() > DEADLINE) throw new Error("scan time limit exceeded");
}

function visit(name) {
  checkBudget();
  if (++entryCount > MAX_ENTRIES) throw new Error("scan entry limit exceeded");
  if (name.split(/[\\/]/).some((part) => BLOCKED_NAME.test(part))) {
    flag(name, "blocked filename");
    return false;
  }
  return true;
}

function reserveBytes(name, size) {
  if (!Number.isSafeInteger(size) || size < 0 || size > MAX_FILE_BYTES) {
    flag(name, "file exceeds 16 MiB scan limit or has invalid size");
    return false;
  }
  totalBytes += size;
  if (totalBytes > MAX_TOTAL_BYTES) throw new Error("aggregate scan byte limit exceeded");
  return true;
}

function scanBytes(bytes, name) {
  // Latin-1 preserves ASCII credential bytes even inside a binary file. File
  // extensions, NUL bytes, inline comments, and path allowlists never skip scans.
  const texts = [bytes.toString("latin1")];
  const utf16 = (bytes[0] === 0xff && bytes[1] === 0xfe) || (bytes[0] === 0xfe && bytes[1] === 0xff);
  if (utf16 && bytes.length % 2) flag(name, "malformed UTF-16 byte length");
  if (bytes[0] === 0xff && bytes[1] === 0xfe) texts.push(bytes.subarray(2).toString("utf16le"));
  if (bytes[0] === 0xfe && bytes[1] === 0xff) {
    texts.push(Buffer.from(bytes.subarray(2, bytes.length - bytes.length % 2)).swap16().toString("utf16le"));
  }
  for (const [rule, pattern] of Object.entries(PATTERNS)) {
    for (const text of texts) {
      const match = pattern.exec(text);
      if (!match) continue;
      const line = text.slice(0, match.index).split("\n").length;
      flag(name, rule, line);
      break;
    }
  }
}

function inside(root, path) {
  const rel = relative(root, path);
  return rel === "" || (!isAbsolute(rel) && rel !== ".." && !rel.startsWith(`..${sep}`));
}

function metadataPath(path) {
  return path.split(/[\\/]/).some((part) => BLOCKED_DIRECTORY.has(part.toLowerCase()));
}

function scanFile(root, abs, name, knownStat) {
  let fd;
  try {
    const stat = knownStat || lstatSync(abs);
    if (stat.isSymbolicLink()) { flag(name, "symlink is not scannable"); return; }
    if (!stat.isFile()) { flag(name, "unsupported file type"); return; }
    if (!inside(root, realpathSync(abs))) { flag(name, "path escapes scan root"); return; }
    if (!(stat.mode & 0o444)) { flag(name, "file is unreadable"); return; }
    if (!reserveBytes(name, stat.size)) return;
    if (constants.O_NOFOLLOW === undefined) throw new Error("safe file opening unavailable");
    fd = openSync(abs, constants.O_RDONLY | constants.O_NOFOLLOW);
    const opened = fstatSync(fd);
    if (!opened.isFile() || opened.dev !== stat.dev || opened.ino !== stat.ino || opened.size !== stat.size) {
      flag(name, "file changed during scan");
      return;
    }
    const chunks = [];
    let size = 0;
    while (true) {
      checkBudget();
      const chunk = Buffer.allocUnsafe(Math.min(64 * 1024, MAX_FILE_BYTES + 1 - size));
      const count = readSync(fd, chunk, 0, chunk.length, null);
      if (!count) break;
      chunks.push(chunk.subarray(0, count));
      size += count;
      if (size > MAX_FILE_BYTES || size > stat.size) { flag(name, "file changed or exceeds scan limit"); return; }
    }
    const after = fstatSync(fd);
    if (size !== stat.size || after.size !== stat.size || after.mtimeMs !== opened.mtimeMs || after.ctimeMs !== opened.ctimeMs) {
      flag(name, "file changed during scan");
      return;
    }
    scanBytes(Buffer.concat(chunks, size), name);
  } catch {
    flag(name, "file could not be safely read");
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

function walk(root, dir) {
  checkBudget();
  let entries;
  try {
    const stat = lstatSync(dir);
    if (!stat.isDirectory() || !inside(root, realpathSync(dir)) || !(stat.mode & 0o444)) {
      throw new Error("unsafe or unreadable directory");
    }
    entries = readdirSync(dir);
  } catch { flag(relative(root, dir) || ".", "directory could not be read"); return; }
  for (const entry of entries) {
    const abs = join(dir, entry);
    const name = relative(root, abs);
    if (!visit(name)) continue;
    let stat;
    try { stat = lstatSync(abs); } catch { flag(name, "entry could not be inspected"); continue; }
    if (stat.isDirectory()) {
      if (metadataPath(entry)) flag(name, "repository metadata in publish directory");
      else walk(root, abs);
    } else scanFile(root, abs, name, stat);
  }
}

function git(args, cwd, maxBuffer = 16 * 1024 * 1024) {
  checkBudget();
  return execFileSync("git", args, {
    cwd, maxBuffer, timeout: Math.max(1, DEADLINE - Date.now()), stdio: ["ignore", "pipe", "pipe"],
  });
}

function scanGit(mode) {
  const root = realpathSync(git(["rev-parse", "--show-toplevel"], process.cwd()).toString("utf8").replace(/\r?\n$/, ""));
  const entries = new Map();
  const initialIndex = git(["ls-files", "--stage", "-z"], root);
  for (const raw of initialIndex.toString("utf8").split("\0").filter(Boolean)) {
    const match = /^(\d{6}) ([0-9a-f]{40,64}) ([0-3])\t([\s\S]+)$/.exec(raw);
    if (!match) throw new Error("invalid index entry");
    const [, fileMode, oid, stage, name] = match;
    if (!entries.has(name)) entries.set(name, []);
    entries.get(name).push({ fileMode, oid, stage });
  }
  // --no-renames represents each rename's destination as an addition, including
  // edited renames. Deleted paths have no bytes to publish and are excluded.
  const names = mode === "staged"
    ? git(["diff", "--cached", "--name-only", "--no-renames", "--diff-filter=ACMTUXB", "-z"], root).toString("utf8").split("\0").filter(Boolean)
    : [...entries.keys()];
  for (const name of names) {
    if (!visit(name)) continue;
    const abs = resolve(root, name);
    if (!inside(root, abs)) { flag(name, "path escapes repository"); continue; }
    const indexed = entries.get(name);
    if (!indexed || indexed.length !== 1 || indexed[0].stage !== "0") { flag(name, "missing or unmerged index entry"); continue; }
    if (!/^100(?:644|755)$/.test(indexed[0].fileMode)) { flag(name, "unsupported index file type"); continue; }
    if (mode === "all") scanFile(root, abs, name);
    else {
      try {
        const sizeText = git(["cat-file", "-s", indexed[0].oid], root).toString("utf8").trim();
        if (!/^\d+$/.test(sizeText)) throw new Error("invalid blob size");
        const size = Number(sizeText);
        if (!reserveBytes(name, size)) continue;
        const bytes = git(["cat-file", "blob", indexed[0].oid], root, MAX_FILE_BYTES + 1);
        if (bytes.length !== size) throw new Error("blob size mismatch");
        scanBytes(bytes, name);
      } catch { flag(name, "index blob could not be safely read"); }
    }
  }
  if (mode === "staged" && !initialIndex.equals(git(["ls-files", "--stage", "-z"], root))) {
    flag("[index]", "index changed during scan");
  }
}

let label = "requested input";
try {
  const args = process.argv.slice(2);
  if (args.length > 1 || (args[0]?.startsWith("--") && !["--staged", "--all"].includes(args[0]))) {
    throw new Error("usage: verify_no_secrets.mjs [directory | --staged | --all]");
  }
  if (["--staged", "--all"].includes(args[0])) {
    label = args[0] === "--staged" ? "staged index blobs" : "tracked working-tree files";
    scanGit(args[0].slice(2));
  } else {
    const target = resolve(process.cwd(), args[0] || "dist");
    label = `publish directory ${displayPath(args[0] || "dist")}`;
    if (!visit(target)) throw new Error("blocked publish directory name");
    if (metadataPath(target)) {
      flag(target, "repository metadata in publish directory");
      throw new Error("blocked publish directory path");
    }
    const stat = lstatSync(target);
    if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error("publish target must be a directory, without a symlink");
    const root = realpathSync(target);
    if (!visit(root)) throw new Error("blocked resolved publish directory name");
    if (metadataPath(root)) {
      flag(target, "repository metadata in publish directory");
      throw new Error("blocked resolved publish directory path");
    }
    walk(root, root);
  }
} catch {
  // Never print exception messages, Git stderr, contents, or matched values.
  flag("[scan]", "scan could not complete safely (input, Git, or resource limit)");
}

if (findingCount) {
  console.error(`SECRET CHECK FAILED — ${label}:`);
  for (const finding of findings) console.error(`  ${finding}`);
  if (findingCount > findings.length) console.error(`  ${findingCount - findings.length} additional findings omitted`);
  console.error("Credential contents were not printed. Resolve every finding before committing or publishing.");
  process.exitCode = 1;
} else console.log(`secret check: clean (${label}; ${entryCount} entries, ${totalBytes} bytes)`);
