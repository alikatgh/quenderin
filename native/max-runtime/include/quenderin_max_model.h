/* Portable lifecycle boundary for a future MAX-backed mobile language model.
 *
 * This header defines ownership, verification, cancellation, streaming and
 * numeric performance reporting. It does NOT tokenize by itself, load GGUF,
 * compile MAX graphs, or ship a vendor runner. A runner is supplied by a
 * separately built and reviewed backend (Android JNI / Apple static library);
 * until one exists, open fails closed with QMAX_UNAVAILABLE.
 *
 * Nothing here downloads weights or contacts a provider. Artifact bytes are
 * verified from app-owned paths against exact sizes and SHA-256 values.
 */
#ifndef QUENDERIN_MAX_MODEL_H
#define QUENDERIN_MAX_MODEL_H

#include "quenderin_max.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define QMAX_MODEL_RUNNER_ABI "quenderin-max-model-runner-1"
#define QMAX_MODEL_MAX_FILES 8
#define QMAX_MODEL_MAX_CONTEXT 4096
#define QMAX_MODEL_MAX_OUTPUT 1024
#define QMAX_MODEL_MAX_PROMPT_BYTES 8192
#define QMAX_MODEL_MAX_PIECE_BYTES 64
#define QMAX_MODEL_MAX_STREAM_BYTES 32768
#define QMAX_MODEL_MAX_FILE_BYTES (8ULL * 1024ULL * 1024ULL * 1024ULL)
#define QMAX_MODEL_MAX_TOTAL_BYTES (12ULL * 1024ULL * 1024ULL * 1024ULL)
#define QMAX_MODEL_MAX_PATH_BYTES 4096

/* One app-owned artifact file. `bytes` is the exact installed size and
 * `sha256` is 64 lowercase hex characters. Splits, adapters and tokenizer
 * files are distinct entries; no entry may be a directory or symlink.
 */
typedef struct {
  const char *path;
  uint64_t bytes;
  char sha256[65];
} QMaxModelFile;

/* A complete, already-reviewed installation. `runner_abi` must equal
 * QMAX_MODEL_RUNNER_ABI exactly. `backend` is the compiled backend identity
 * that the runner actually loaded; a catalog label is not sufficient.
 *
 * Paths must be in app-private storage. Every file is hashed immediately
 * before the runner opens it, but MAX opens the path itself: a concurrent
 * writer with access to that directory can still replace bytes between the
 * final check and the vendor open. Never place these files in shared or
 * user-writable external storage.
 */
typedef struct {
  const char *runner_name;
  const char *runner_abi;
  const char *backend;
  uint32_t context_tokens;
  uint32_t max_output_tokens;
  const QMaxModelFile *files;
  size_t file_count;
} QMaxModelReceipt;

typedef struct QMaxModel QMaxModel;

/* A vendor runner owns all model, tokenizer and sampling semantics. The
 * adapter never inspects weights and never copies a second token pipeline.
 * The runner table must stay valid for the lifetime of every model handle
 * (static storage is the intended use). Every callback runs while the adapter
 * holds the model's single-flight lease; callbacks must not call
 * qmax_model_open/close on the same model.
 */
typedef struct {
  const char *abi;
  /* Returns an opaque runner state, or NULL after filling `error`. */
  void *(*open)(const QMaxModelReceipt *receipt, QMaxError *error);
  /* Tokenizes the bounded prompt into at most `capacity` token ids. */
  QMaxCode (*tokenize)(void *runner, const char *utf8, size_t bytes,
                       int32_t *tokens, size_t capacity, size_t *count,
                       QMaxError *error);
  /* Produces the next token for tokens[0..count). `piece_capacity` is at most
   * QMAX_MODEL_MAX_PIECE_BYTES. The piece may contain a partial UTF-8
   * character; the adapter reassembles characters before calling emit.
   * Callbacks must return bounded error messages without paths or prompt text.
   */
  QMaxCode (*next_token)(void *runner, const int32_t *tokens, size_t count,
                         float temperature, float top_p, uint32_t seed,
                         int32_t *token, char *piece, size_t piece_capacity,
                         size_t *piece_bytes, int *end_of_generation,
                         QMaxError *error);
  void (*close)(void *runner);
} QMaxModelRunner;

typedef struct {
  const char *prompt;
  size_t prompt_bytes;
  uint32_t max_tokens;
  float temperature;
  float top_p;
  uint32_t seed;
} QMaxModelRequest;

/* Return 1 to keep streaming, 0 to stop. Called only between whole tokens. */
typedef int (*QMaxModelEmit)(void *context, const char *utf8, size_t bytes);
typedef int (*QMaxModelShouldStop)(void *context);

/* status: 0 complete, 1 cancelled, 2 runner error, 3 output cap reached,
 * 4 streaming sink stopped, 5 context/output budget clamped, 6 rejected
 * before generation. All durations are milliseconds and are only reported for
 * the current call. Prompt processing happens inside the first runner step, so
 * prefill_ms and first_token_ms describe the same interval here; a runner that
 * separates them can report its own timing later.
 */
typedef struct {
  uint32_t prompt_tokens;
  uint32_t decoded_tokens;
  double prefill_ms;
  double decode_ms;
  double first_token_ms;
  double max_gap_ms;
  int status;
  int cache_mode;
} QMaxModelPerformance;

typedef struct {
  int contract_ok;
  int load_probe_passed;
  int available;
  char runner[64];
  char backend[16];
  char reason[96];
  uint32_t context_tokens;
  uint32_t max_output_tokens;
} QMaxModelCapability;

/* Validates schema, exact file sizes, regular-file identity and SHA-256
 * values. Never opens a runner. Hashing is mandatory; there is no
 * size-only mode.
 */
QMaxCode qmax_model_verify(const QMaxModelReceipt *receipt, QMaxError *error);

/* Verifies the receipt, requires explicit MAX telemetry/crash-reporting
 * opt-outs, then opens the runner. Opens fail closed without a runner,
 * an exact ABI, opt-outs or a verified installation.
 */
QMaxCode qmax_model_open(const QMaxModelRunner *runner,
                         const QMaxModelReceipt *receipt, QMaxModel **out,
                         QMaxError *error);

/* Reports the static contract and whether a real load probe has passed.
 * `load_probe_passed` must come from an actual open/generate probe; passing 1
 * without one misrepresents support and is not done by this module.
 * `available` also requires the telemetry/crash-reporting opt-outs that
 * qmax_model_open enforces.
 */
QMaxCode qmax_model_capability(const QMaxModelRunner *runner,
                               const QMaxModelReceipt *receipt,
                               int load_probe_passed,
                               QMaxModelCapability *out);

/* Single-flight, bounded generation. Returns QMAX_OK for status 0/3/5,
 * QMAX_CANCELLED for status 1/4 and the runner's code for status 2.
 * `performance` is zeroed at entry and populated for the current call only.
 */
QMaxCode qmax_model_generate(QMaxModel *model, const QMaxModelRequest *request,
                             QMaxModelEmit emit, void *emit_context,
                             QMaxModelShouldStop should_stop,
                             void *stop_context,
                             QMaxModelPerformance *performance,
                             QMaxError *error);

/* Requests cancellation of the generation currently in flight. Safe to call
 * from the emit callback or another thread. The runner's current callback is
 * not preempted; the next token boundary observes it. A request made while the
 * model is idle is cleared when the next generation starts, so callers must
 * cancel after generate has begun (for example from emit).
 */
void qmax_model_cancel(QMaxModel *model);

/* Frees the runner and all adapter state. Returns QMAX_BUSY without freeing
 * anything if a generation is active; retry after the generation returns.
 * The caller owns handle lifetime: do not race close with a new generate on
 * another thread.
 */
QMaxCode qmax_model_close(QMaxModel *model);

#ifdef __cplusplus
}
#endif
#endif
