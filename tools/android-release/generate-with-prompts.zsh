#!/bin/zsh
# Private human Terminal only. No actual key generation runs in agent tests.
set +x
set -eu
umask 077
if [[ ! -t 0 || ! -t 1 || $# -ne 0 ]]; then
  print -u2 'Run this command without arguments in your own interactive Terminal.'
  exit 2
fi
unset QUENDERIN_UPLOAD_KEYSTORE QUENDERIN_UPLOAD_ALIAS QUENDERIN_UPLOAD_STORE_PASSWORD QUENDERIN_UPLOAD_KEY_PASSWORD
trap 'unset QUENDERIN_UPLOAD_KEYSTORE QUENDERIN_UPLOAD_ALIAS QUENDERIN_UPLOAD_STORE_PASSWORD QUENDERIN_UPLOAD_KEY_PASSWORD quenderin_new_directory quenderin_password_confirmation' EXIT
read -rs 'quenderin_new_directory?New private output directory outside Git, absolute path (hidden): '
print
read -rs 'QUENDERIN_UPLOAD_STORE_PASSWORD?New upload-key password, at least 12 characters (hidden): '
print
read -rs 'quenderin_password_confirmation?Confirm the same password (hidden): '
print
if [[ "$QUENDERIN_UPLOAD_STORE_PASSWORD" != "$quenderin_password_confirmation" ]]; then
  print -u2 'Passwords differ; nothing was created.'
  exit 1
fi
unset quenderin_password_confirmation
QUENDERIN_UPLOAD_KEYSTORE="${quenderin_new_directory%/}/upload-keystore.p12"
QUENDERIN_UPLOAD_ALIAS='quenderin-upload'
QUENDERIN_UPLOAD_KEY_PASSWORD="$QUENDERIN_UPLOAD_STORE_PASSWORD"
unset quenderin_new_directory
export QUENDERIN_UPLOAD_KEYSTORE QUENDERIN_UPLOAD_ALIAS QUENDERIN_UPLOAD_STORE_PASSWORD QUENDERIN_UPLOAD_KEY_PASSWORD
python3 -B "${0:A:h}/generate_upload_key.py" generate
