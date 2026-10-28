#!/bin/zsh
# Human Terminal entry only. Nothing is persisted; Varlock receives exported inputs.
set +x
set -eu
if [[ ! -t 0 || ! -t 1 ]]; then
  print -u2 'Run this command in your own interactive Terminal.'
  exit 2
fi
unset QUENDERIN_UPLOAD_KEYSTORE QUENDERIN_UPLOAD_ALIAS QUENDERIN_UPLOAD_STORE_PASSWORD QUENDERIN_UPLOAD_KEY_PASSWORD
trap 'unset QUENDERIN_UPLOAD_KEYSTORE QUENDERIN_UPLOAD_ALIAS QUENDERIN_UPLOAD_STORE_PASSWORD QUENDERIN_UPLOAD_KEY_PASSWORD' EXIT
read -rs 'QUENDERIN_UPLOAD_KEYSTORE?Existing upload keystore absolute path (hidden): '
print
read -rs 'QUENDERIN_UPLOAD_ALIAS?Existing upload key alias (hidden): '
print
read -rs 'QUENDERIN_UPLOAD_STORE_PASSWORD?Keystore password (hidden): '
print
read -rs 'QUENDERIN_UPLOAD_KEY_PASSWORD?Key password (hidden; repeat store password if identical): '
print
export QUENDERIN_UPLOAD_KEYSTORE QUENDERIN_UPLOAD_ALIAS QUENDERIN_UPLOAD_STORE_PASSWORD QUENDERIN_UPLOAD_KEY_PASSWORD
python3 "${0:A:h}/sign_aab.py" sign "$@"
