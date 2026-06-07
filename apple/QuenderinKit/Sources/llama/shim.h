// Umbrella shim for the `llama` system-library module. Angled include so it is
// found via the `-I$QUENDERIN_LLAMA_DIR/include` search path injected by
// Package.swift (the header is NOT vendored here).
#include <llama.h>
