# r31 — File-IO audit (2026-07-11)

**Verdict: clean.** Every user/model-influenced path is gated (verified on current main):
- `read_file`: home containment + symlink resolution + sensitive-store denylist (~/.ssh, .aws,
  browser profiles, key/env/credential name patterns) + 8 kB cap.
- `note_save` / notes routes: `sanitizeNoteFilename` + title sanitization.
- Sessions: `sessionPath` strips to `[a-zA-Z0-9-_]`≤64 on read AND write; export/delete go
  through the same helper.
- Docs route: default-deny allowlist + `path.basename` + `.md`-only (r15).
- Model downloads: destination filenames come from the repo-controlled catalog, not user input;
  downloads stream-verify sha256 (`modelIntegrity`).
- All persistence now atomic write-temp-rename (r16).
