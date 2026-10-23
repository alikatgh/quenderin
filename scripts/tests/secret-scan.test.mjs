import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, symlinkSync, truncateSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const scanner = resolve(dirname(fileURLToPath(import.meta.url)), "../verify_no_secrets.mjs");
const synthetic = {
  google_api_key: ["AI", "za", "A".repeat(35)].join(""),
  openai_key: ["s", "k-", "proj-", "B".repeat(40)].join(""),
  github_token: ["gh", "p_", "C".repeat(36)].join(""),
  github_fine_grained: ["github", "_pat_", "D".repeat(60)].join(""),
  aws_access_key: ["A", "SIA", "E".repeat(16)].join(""),
  slack_token: ["xo", "xb-", "F".repeat(24)].join(""),
  huggingface_token: ["h", "f_", "G".repeat(32)].join(""),
  npm_token: ["np", "m_", "H".repeat(36)].join(""),
  stripe_key: ["s", "k_live_", "J".repeat(24)].join(""),
  private_key: ["-----BE", "GIN ENCRYPTED ", "PRIVATE KEY", "-----"].join(""),
};
const secret = synthetic.github_token;

function fixture(t, git = false) {
  const root = mkdtempSync(join(process.env.SECRET_SCAN_TEST_ROOT || tmpdir(), "quenderin-secret-scan-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  if (git) runGit(root, ["init", "-q"]);
  return root;
}

function runGit(root, args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
}

function scan(root, args, env = {}) {
  const result = spawnSync(process.execPath, [scanner, ...args], {
    cwd: root, encoding: "utf8", timeout: 15_000, maxBuffer: 1024 * 1024,
    env: { ...process.env, ...env },
  });
  assert.equal(result.error, undefined, "scanner must finish within its test deadline");
  const output = result.stdout + result.stderr;
  for (const value of Object.values(synthetic)) {
    assert.equal(output.includes(value), false, "scanner must redact matched values");
  }
  return { status: result.status, output };
}

function commit(root) {
  runGit(root, ["-c", "user.name=Scanner Test", "-c", "user.email=scanner@example.invalid",
    "-c", "core.hooksPath=/dev/null", "commit", "-qm", "synthetic baseline"]);
}

test("clean directory scans every extension without requiring a Git repository", (t) => {
  const root = fixture(t);
  writeFileSync(join(root, "asset.png"), Buffer.from([0, 1, 2, 3]));
  writeFileSync(join(root, "normal.txt"), "No credential content.\n");
  assert.equal(scan(root, ["."]).status, 0);
});

test("staged secret remains blocked after a clean unstaged edit", (t) => {
  const root = fixture(t, true);
  writeFileSync(join(root, "config.txt"), secret + "\n");
  runGit(root, ["add", "config.txt"]);
  writeFileSync(join(root, "config.txt"), "clean unstaged content\n");
  const result = scan(root, ["--staged"]);
  assert.equal(result.status, 1);
  assert.match(result.output, /\[github_token\]/);
});

test("clean index bytes pass despite a secret in the unstaged worktree", (t) => {
  const root = fixture(t, true);
  writeFileSync(join(root, "config.txt"), "clean staged content\n");
  runGit(root, ["add", "config.txt"]);
  writeFileSync(join(root, "config.txt"), secret + "\n");
  assert.equal(scan(root, ["--staged"]).status, 0);
  assert.equal(scan(root, ["--all"]).status, 1);
});

test("staged blobs can be checked when the worktree file is missing", (t) => {
  const root = fixture(t, true);
  writeFileSync(join(root, "config.txt"), "clean staged content\n");
  runGit(root, ["add", "config.txt"]);
  rmSync(join(root, "config.txt"));
  assert.equal(scan(root, ["--staged"]).status, 0);
  assert.equal(scan(root, ["--all"]).status, 1);
});

test("edited renames scan destination index bytes", (t) => {
  const root = fixture(t, true);
  const clean = "Ordinary non-sensitive line.\n".repeat(100);
  writeFileSync(join(root, "original.txt"), clean);
  runGit(root, ["add", "original.txt"]);
  commit(root);
  renameSync(join(root, "original.txt"), join(root, "renamed.txt"));
  writeFileSync(join(root, "renamed.txt"), clean + secret + "\n");
  runGit(root, ["add", "-A"]);
  assert.match(runGit(root, ["diff", "--cached", "--name-status"]), /^R\d+\s/);
  writeFileSync(join(root, "renamed.txt"), clean);
  const result = scan(root, ["--staged"]);
  assert.equal(result.status, 1);
  assert.match(result.output, /renamed\.txt.*\[github_token\]/);
});

test("every supported rule is detected and values stay out of diagnostics", (t) => {
  const root = fixture(t);
  for (const [name, value] of Object.entries(synthetic)) {
    writeFileSync(join(root, name + ".txt"), "header\n" + value + "\n");
  }
  const result = scan(root, ["."]);
  assert.equal(result.status, 1);
  for (const name of ["google_api_key", "openai_key", "github_token", "aws_access_key",
    "slack_token", "huggingface_token", "npm_token", "stripe_key", "private_key"]) {
    assert.ok(result.output.includes("[" + name + "]"), "expected rule: " + name);
  }
  assert.match(result.output, /:2  \[github_token\]/);
});

test("binary NUL bytes, ignored-looking extensions, and files over the old 2 MB cap are scanned", (t) => {
  const root = fixture(t);
  writeFileSync(join(root, "asset.png"),
    Buffer.concat([Buffer.alloc(2_100_000), Buffer.from(secret), Buffer.from([0, 1])]));
  const result = scan(root, ["."]);
  assert.equal(result.status, 1);
  assert.match(result.output, /\[github_token\]/);
});

test("UTF-16 credential text is scanned", (t) => {
  const root = fixture(t);
  writeFileSync(join(root, "little.txt"), Buffer.concat([Buffer.from([255, 254]), Buffer.from(secret, "utf16le")]));
  writeFileSync(join(root, "big.txt"), Buffer.concat([Buffer.from([254, 255]), Buffer.from(secret, "utf16le").swap16()]));
  const result = scan(root, ["."]);
  assert.equal(result.status, 1);
  assert.match(result.output, /little\.txt.*\[github_token\]/);
  assert.match(result.output, /big\.txt.*\[github_token\]/);
});

test("odd-length UTF-16BE still scans complete characters and fails closed", (t) => {
  const root = fixture(t);
  writeFileSync(join(root, "odd.txt"), Buffer.concat([
    Buffer.from([254, 255]), Buffer.from(secret, "utf16le").swap16(), Buffer.from([0]),
  ]));
  const result = scan(root, ["."]);
  assert.equal(result.status, 1);
  assert.match(result.output, /\[github_token\]/);
  assert.match(result.output, /\[malformed UTF-16 byte length\]/);
});

test("broad path allowlists and inline allow comments cannot hide credentials", (t) => {
  const root = fixture(t);
  writeFileSync(join(root, ".secret-scan-allow"), "config.txt\n");
  writeFileSync(join(root, "config.txt"), secret + " // secret_scan:allow\n");
  const result = scan(root, ["."]);
  assert.equal(result.status, 1);
  assert.match(result.output, /\[github_token\]/);
});

test("forbidden filenames and private-key stores fail before opening contents", (t) => {
  const root = fixture(t);
  for (const name of [".env", ".env.example", ".environment", "secrets.json", "secrets.txt",
    "private.pem", "private.key", "private.p8", "private.p12", "private.pfx", "private.jks",
    "private.keystore", "id_ed25519"]) {
    // Dangling links would fail content access; the filename rule must win first.
    symlinkSync("does-not-exist", join(root, name));
  }
  const result = scan(root, ["."]);
  assert.equal(result.status, 1);
  assert.equal((result.output.match(/\[blocked filename\]/g) || []).length, 13);
  assert.doesNotMatch(result.output, /symlink|safely read/);
});

test("staged forbidden filenames are rejected without reading their blobs", (t) => {
  const root = fixture(t, true);
  symlinkSync("does-not-exist", join(root, ".env.local"));
  runGit(root, ["add", ".env.local"]);
  const result = scan(root, ["--staged"]);
  assert.equal(result.status, 1);
  assert.match(result.output, /\[blocked filename\]/);
  assert.doesNotMatch(result.output, /\[(?:unsupported index file type|index blob could not be safely read)\]/);
});

test("explicit publish targets reject forbidden ancestor names before content access", (t) => {
  const root = fixture(t);
  for (const ancestor of ["secrets.fixture", ".env.fixture"]) {
    mkdirSync(join(root, ancestor, "publish"), { recursive: true });
    writeFileSync(join(root, ancestor, "publish", "config.txt"), secret);
    const result = scan(root, [join(ancestor, "publish")]);
    assert.equal(result.status, 1);
    assert.match(result.output, /\[blocked filename\]/);
    assert.doesNotMatch(result.output, /\[github_token\]/);
    const alias = join(root, "alias-" + ancestor.replace(/[^a-z]/gi, ""));
    symlinkSync(join(root, ancestor), alias);
    const aliased = scan(root, [join(alias, "publish")]);
    assert.equal(aliased.status, 1);
    assert.match(aliased.output, /\[blocked filename\]/);
    assert.doesNotMatch(aliased.output, /\[github_token\]/);
  }
});

test("an index changed between metadata listing and blob scanning cannot pass", (t) => {
  const root = fixture(t, true);
  const wrapper = fixture(t);
  writeFileSync(join(root, "config.txt"), "clean index bytes\n");
  runGit(root, ["add", "config.txt"]);
  writeFileSync(join(root, "config.txt"), secret);
  const realGit = execFileSync("which", ["git"], { encoding: "utf8" }).trim();
  const script = [
    "#!" + process.execPath,
    "const { spawnSync, execFileSync } = require('node:child_process');",
    "const { existsSync, writeFileSync } = require('node:fs');",
    "const args = process.argv.slice(2);",
    "const result = spawnSync(process.env.SCANNER_TEST_REAL_GIT, args, { maxBuffer: 20 * 1024 * 1024 });",
    "if (args[0] === 'ls-files' && !existsSync(process.env.SCANNER_TEST_MARKER)) {",
    "  writeFileSync(process.env.SCANNER_TEST_MARKER, 'changed');",
    "  execFileSync(process.env.SCANNER_TEST_REAL_GIT, ['add', 'config.txt']);",
    "}",
    "if (result.stdout) process.stdout.write(result.stdout);",
    "if (result.stderr) process.stderr.write(result.stderr);",
    "process.exit(result.status ?? 1);",
  ].join("\n");
  writeFileSync(join(wrapper, "git"), script, { mode: 0o700 });
  const result = scan(root, ["--staged"], {
    PATH: wrapper + delimiter + process.env.PATH,
    SCANNER_TEST_REAL_GIT: realGit,
    SCANNER_TEST_MARKER: join(wrapper, "changed"),
  });
  assert.equal(result.status, 1);
  assert.match(result.output, /\[index changed during scan\]/);
});

test("publish-directory symlinks cannot escape, loop, or silently disappear", (t) => {
  const root = fixture(t);
  mkdirSync(join(root, "publish"));
  writeFileSync(join(root, "outside.txt"), secret);
  symlinkSync("../outside.txt", join(root, "publish", "outside"));
  symlinkSync(".", join(root, "publish", "loop"));
  symlinkSync("missing", join(root, "publish", "dangling"));
  const result = scan(root, ["publish"]);
  assert.equal(result.status, 1);
  assert.equal((result.output.match(/\[symlink is not scannable\]/g) || []).length, 3);
  assert.doesNotMatch(result.output, /\[github_token\]/);
});

test("tracked symlinks and index gitlinks fail closed", (t) => {
  const root = fixture(t, true);
  writeFileSync(join(root, "clean.txt"), "clean\n");
  runGit(root, ["add", "clean.txt"]);
  commit(root);
  symlinkSync("clean.txt", join(root, "linked.txt"));
  runGit(root, ["add", "linked.txt"]);
  const oid = runGit(root, ["rev-parse", "HEAD"]).trim();
  runGit(root, ["update-index", "--add", "--cacheinfo", "160000," + oid + ",submodule"]);
  const result = scan(root, ["--staged"]);
  assert.equal(result.status, 1);
  assert.equal((result.output.match(/\[unsupported index file type\]/g) || []).length, 2);
});

test("tracked files cannot escape through a symlinked parent directory", (t) => {
  const root = fixture(t, true);
  const outside = fixture(t);
  mkdirSync(join(root, "folder"));
  writeFileSync(join(root, "folder", "config.txt"), "clean\n");
  runGit(root, ["add", "folder/config.txt"]);
  rmSync(join(root, "folder"), { recursive: true });
  writeFileSync(join(outside, "config.txt"), secret);
  symlinkSync(outside, join(root, "folder"));
  const result = scan(root, ["--all"]);
  assert.equal(result.status, 1);
  assert.match(result.output, /\[path escapes scan root\]/);
  assert.doesNotMatch(result.output, /\[github_token\]/);
});

test("unreadable files and directories do not produce a clean result", (t) => {
  const root = fixture(t);
  writeFileSync(join(root, "unreadable.txt"), "clean\n");
  mkdirSync(join(root, "unreadable-directory"));
  chmodSync(join(root, "unreadable.txt"), 0);
  chmodSync(join(root, "unreadable-directory"), 0);
  try {
    const result = scan(root, ["."]);
    assert.equal(result.status, 1);
    assert.match(result.output, /\[file is unreadable\]/);
    assert.match(result.output, /\[directory could not be read\]/);
  } finally {
    chmodSync(join(root, "unreadable.txt"), 0o600);
    chmodSync(join(root, "unreadable-directory"), 0o700);
  }
});

test("oversize files fail closed in directory, tracked, and staged modes", (t) => {
  const root = fixture(t, true);
  const large = join(root, "large.bin");
  writeFileSync(large, "");
  truncateSync(large, 16 * 1024 * 1024 + 1);
  runGit(root, ["add", "large.bin"]);
  for (const args of [["--all"], ["--staged"]]) {
    const result = scan(root, args);
    assert.equal(result.status, 1);
    assert.match(result.output, /file exceeds 16 MiB scan limit/);
  }
  mkdirSync(join(root, "publish"));
  renameSync(large, join(root, "publish", "large.bin"));
  assert.match(scan(root, ["publish"]).output, /file exceeds 16 MiB scan limit/);
});

test("missing inputs, non-directory targets, non-repositories, and invalid arguments fail", (t) => {
  const root = fixture(t);
  writeFileSync(join(root, "plain.txt"), "clean\n");
  for (const args of [["missing"], ["plain.txt"], ["--all"], ["--staged"], ["--unknown"], ["--all", "--staged"]]) {
    assert.equal(scan(root, args).status, 1, "invalid input must fail");
  }
});

test("repository metadata is rejected from publish directories", (t) => {
  const root = fixture(t, true);
  const result = scan(root, ["."]);
  assert.equal(result.status, 1);
  assert.match(result.output, /repository metadata in publish directory/);
});

test("explicit and resolved publish targets reject metadata roots and ancestors", (t) => {
  const root = fixture(t);
  for (const metadata of [".git", ".hg", ".svn"]) {
    mkdirSync(join(root, metadata, "objects"), { recursive: true });
    for (const target of [metadata, join(metadata, "objects")]) {
      const result = scan(root, [target]);
      assert.equal(result.status, 1);
      assert.match(result.output, /repository metadata in publish directory/);
    }
  }
  symlinkSync(".git", join(root, "linked-parent"));
  const result = scan(root, [join("linked-parent", "objects")]);
  assert.equal(result.status, 1);
  assert.match(result.output, /repository metadata in publish directory/);
});

test("credential-shaped and control-character filenames cannot leak or inject diagnostics", (t) => {
  const root = fixture(t);
  writeFileSync(join(root, "prefix_" + secret + "_suffix\nname.txt"), secret);
  const result = scan(root, ["."]);
  assert.equal(result.status, 1);
  assert.match(result.output, /redacted filename/);
});

test("the CI workflow runs negative tests with read-only permissions and a finite timeout", () => {
  const workflow = readFileSync(resolve(dirname(scanner), "../.github/workflows/secret-scan.yml"), "utf8");
  assert.match(workflow, /permissions:\n  contents: read/);
  assert.match(workflow, /timeout-minutes: 5/);
  assert.match(workflow, /persist-credentials: false/);
  assert.match(workflow, /node --test scripts\/tests\/secret-scan\.test\.mjs/);
});
