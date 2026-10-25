#ifndef QUENDERIN_CMAXMODEL_SUPPORT_H
#define QUENDERIN_CMAXMODEL_SUPPORT_H

#include "quenderin_max_model.h"

#include <string.h>

/* Small C helpers so Swift never guesses at imported enum or tuple layouts. */

static inline int qmax_code_value(QMaxCode code) { return (int)code; }
static inline QMaxCode qmax_code_ok(void) { return QMAX_OK; }
static inline QMaxCode qmax_code_invalid(void) { return QMAX_INVALID_ARGUMENT; }
static inline QMaxCode qmax_code_unavailable(void) { return QMAX_UNAVAILABLE; }
static inline QMaxCode qmax_code_runtime(void) { return QMAX_RUNTIME_ERROR; }
static inline QMaxCode qmax_code_cancelled(void) { return QMAX_CANCELLED; }
static inline QMaxCode qmax_code_contract(void) { return QMAX_CONTRACT_MISMATCH; }
static inline QMaxCode qmax_code_busy(void) { return QMAX_BUSY; }

static inline const char *qmax_runner_abi(void) { return QMAX_MODEL_RUNNER_ABI; }

static inline void qmax_file_set_sha256(QMaxModelFile *file, const char *hex) {
  if (!file) return;
  memset(file->sha256, 0, sizeof(file->sha256));
  if (!hex) return;
  for (size_t i = 0; i < 64 && hex[i]; ++i) file->sha256[i] = hex[i];
  file->sha256[64] = '\0';
}

static inline const char *qmax_error_message(const QMaxError *error) {
  return error ? error->message : "";
}

static inline const char *qmax_capability_runner(const QMaxModelCapability *value) {
  return value ? value->runner : "";
}

static inline const char *qmax_capability_backend(const QMaxModelCapability *value) {
  return value ? value->backend : "";
}

static inline const char *qmax_capability_reason(const QMaxModelCapability *value) {
  return value ? value->reason : "";
}

#endif
