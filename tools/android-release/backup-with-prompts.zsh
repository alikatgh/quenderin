#!/bin/zsh
# Run only in the human's private interactive Terminal. age owns its prompts.
set +x
set -eu
umask 077
if [[ ! -t 0 || ! -t 1 || $# -ne 0 ]]; then
  print -u2 '{"restoreVerified":false,"status":"interactive_terminal_required"}'
  exit 2
fi
unset -m 'QUENDERIN_UPLOAD_*'
python3 -B "${0:A:h}/backup_upload_key.py" backup
