/* Portable model-adapter boundary. See quenderin_max_model.h for the contract.
 * This file has no vendor dependency and performs no network or model work.
 */
#define _POSIX_C_SOURCE 200809L
#include "quenderin_max_model.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

/* ---------- bounded diagnostics ---------- */

static void copy_text(char *destination, size_t capacity, const char *source);

static QMaxCode fail(QMaxError *error, QMaxCode code, const char *message) {
  if (error) {
    error->code = code;
    copy_text(error->message, sizeof(error->message), message);
  }
  return code;
}

static QMaxCode fail_keep(QMaxError *error, QMaxCode code, const char *message) {
  if (error && error->message[0]) return code;
  return fail(error, code, message);
}

static void reset_error(QMaxError *error) {
  if (!error) return;
  error->code = QMAX_OK;
  error->message[0] = '\0';
}

static int text_ok(const char *text, size_t maximum) {
  if (!text) return 0;
  size_t length = strnlen(text, maximum + 1);
  return length > 0 && length <= maximum;
}

static void copy_text(char *destination, size_t capacity, const char *source) {
  if (!destination || capacity == 0) return;
  size_t length = source ? strnlen(source, capacity - 1) : 0;
  if (length) memcpy(destination, source, length);
  destination[length] = '\0';
}

static int hex64(const char *value) {
  for (size_t i = 0; i < 64; ++i) {
    char c = value[i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return 0;
  }
  return value[64] == '\0';
}

/* ---------- SHA-256 (FIPS 180-4), used only for local artifact identity ---------- */

typedef struct {
  uint32_t state[8];
  uint64_t bits;
  unsigned char block[64];
  size_t used;
} Sha256;

static const uint32_t kSha256[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu,
    0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u,
    0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u,
    0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u,
    0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
    0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu,
    0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u,
    0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u, 0x1e376c08u,
    0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu,
    0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u};

static uint32_t rotr(uint32_t value, int shift) {
  return (value >> shift) | (value << (32 - shift));
}

static void sha256_init(Sha256 *ctx) {
  static const uint32_t initial[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u,
                                      0xa54ff53au, 0x510e527fu, 0x9b05688cu,
                                      0x1f83d9abu, 0x5be0cd19u};
  memcpy(ctx->state, initial, sizeof(initial));
  ctx->bits = 0;
  ctx->used = 0;
}

static void sha256_block(Sha256 *ctx, const unsigned char *block) {
  uint32_t w[64];
  for (int i = 0; i < 16; ++i) {
    w[i] = ((uint32_t)block[i * 4] << 24) | ((uint32_t)block[i * 4 + 1] << 16) |
           ((uint32_t)block[i * 4 + 2] << 8) | (uint32_t)block[i * 4 + 3];
  }
  for (int i = 16; i < 64; ++i) {
    uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
    uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint32_t a = ctx->state[0], b = ctx->state[1], c = ctx->state[2],
           d = ctx->state[3], e = ctx->state[4], f = ctx->state[5],
           g = ctx->state[6], h = ctx->state[7];
  for (int i = 0; i < 64; ++i) {
    uint32_t sum1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
    uint32_t choice = (e & f) ^ (~e & g);
    uint32_t temp1 = h + sum1 + choice + kSha256[i] + w[i];
    uint32_t sum0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
    uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
    uint32_t temp2 = sum0 + majority;
    h = g;
    g = f;
    f = e;
    e = d + temp1;
    d = c;
    c = b;
    b = a;
    a = temp1 + temp2;
  }
  ctx->state[0] += a;
  ctx->state[1] += b;
  ctx->state[2] += c;
  ctx->state[3] += d;
  ctx->state[4] += e;
  ctx->state[5] += f;
  ctx->state[6] += g;
  ctx->state[7] += h;
}

static void sha256_update(Sha256 *ctx, const unsigned char *data, size_t length) {
  ctx->bits += (uint64_t)length * 8;
  while (length > 0) {
    size_t room = sizeof(ctx->block) - ctx->used;
    size_t take = length < room ? length : room;
    memcpy(ctx->block + ctx->used, data, take);
    ctx->used += take;
    data += take;
    length -= take;
    if (ctx->used == sizeof(ctx->block)) {
      sha256_block(ctx, ctx->block);
      ctx->used = 0;
    }
  }
}

static void sha256_final(Sha256 *ctx, unsigned char digest[32]) {
  uint64_t bits = ctx->bits;
  unsigned char pad = 0x80;
  sha256_update(ctx, &pad, 1);
  unsigned char zero = 0;
  while (ctx->used != 56) sha256_update(ctx, &zero, 1);
  unsigned char length[8];
  for (int i = 0; i < 8; ++i) length[7 - i] = (unsigned char)(bits >> (i * 8));
  sha256_update(ctx, length, sizeof(length));
  for (int i = 0; i < 8; ++i) {
    digest[i * 4] = (unsigned char)(ctx->state[i] >> 24);
    digest[i * 4 + 1] = (unsigned char)(ctx->state[i] >> 16);
    digest[i * 4 + 2] = (unsigned char)(ctx->state[i] >> 8);
    digest[i * 4 + 3] = (unsigned char)ctx->state[i];
  }
}

/* ---------- receipt schema and artifact verification ---------- */

static QMaxCode schema(const QMaxModelReceipt *receipt, QMaxError *error) {
  if (!receipt) return fail(error, QMAX_INVALID_ARGUMENT, "Model receipt is required");
  if (!text_ok(receipt->runner_name, 63)) return fail(error, QMAX_CONTRACT_MISMATCH, "Runner identity is missing or too long");
  if (!text_ok(receipt->runner_abi, 63)) return fail(error, QMAX_CONTRACT_MISMATCH, "Runner ABI is missing or too long");
  if (!text_ok(receipt->backend, 15)) return fail(error, QMAX_CONTRACT_MISMATCH, "Compiled backend identity is missing or too long");
  if (receipt->context_tokens < 1 || receipt->context_tokens > QMAX_MODEL_MAX_CONTEXT)
    return fail(error, QMAX_CONTRACT_MISMATCH, "Context budget is outside the reviewed range");
  if (receipt->max_output_tokens < 1 || receipt->max_output_tokens > QMAX_MODEL_MAX_OUTPUT ||
      receipt->max_output_tokens > receipt->context_tokens)
    return fail(error, QMAX_CONTRACT_MISMATCH, "Output budget is outside the reviewed range");
  if (!receipt->files || receipt->file_count < 1 || receipt->file_count > QMAX_MODEL_MAX_FILES)
    return fail(error, QMAX_CONTRACT_MISMATCH, "One to eight artifact files are required");
  uint64_t total = 0;
  for (size_t i = 0; i < receipt->file_count; ++i) {
    const QMaxModelFile *file = &receipt->files[i];
    if (!text_ok(file->path, QMAX_MODEL_MAX_PATH_BYTES))
      return fail(error, QMAX_CONTRACT_MISMATCH, "Artifact path is missing or too long");
    if (file->bytes < 1 || file->bytes > QMAX_MODEL_MAX_FILE_BYTES)
      return fail(error, QMAX_CONTRACT_MISMATCH, "Artifact size is outside the reviewed range");
    if (!hex64(file->sha256))
      return fail(error, QMAX_CONTRACT_MISMATCH, "Artifact SHA-256 must be 64 lowercase hex characters");
    if (total > QMAX_MODEL_MAX_TOTAL_BYTES - file->bytes)
      return fail(error, QMAX_CONTRACT_MISMATCH, "Artifact set exceeds the total byte budget");
    total += file->bytes;
  }
  return QMAX_OK;
}

static QMaxCode verify_file(const QMaxModelFile *file, QMaxError *error) {
  struct stat info;
  if (lstat(file->path, &info) != 0 || !S_ISREG(info.st_mode))
    return fail(error, QMAX_CONTRACT_MISMATCH, "Artifact file is missing, a symlink, or not a regular file");
  if (info.st_size < 0 || (uint64_t)info.st_size != file->bytes)
    return fail(error, QMAX_CONTRACT_MISMATCH, "Artifact size differs from the verified receipt");

  FILE *stream = fopen(file->path, "rb");
  if (!stream) return fail(error, QMAX_UNAVAILABLE, "Verified artifact cannot be read");
  const size_t chunk = 16384;
  unsigned char *buffer = malloc(chunk);
  if (!buffer) {
    fclose(stream);
    return fail(error, QMAX_UNAVAILABLE, "Cannot allocate the artifact hash buffer");
  }
  Sha256 ctx;
  sha256_init(&ctx);
  uint64_t read_total = 0;
  QMaxCode result = QMAX_OK;
  for (;;) {
    size_t got = fread(buffer, 1, chunk, stream);
    if (got > 0) {
      read_total += got;
      if (read_total > file->bytes) {
        result = fail(error, QMAX_CONTRACT_MISMATCH, "Artifact grew while it was being verified");
        break;
      }
      sha256_update(&ctx, buffer, got);
    }
    if (got < chunk) {
      if (ferror(stream)) result = fail(error, QMAX_UNAVAILABLE, "Verified artifact cannot be read");
      break;
    }
  }
  free(buffer);
  fclose(stream);
  if (result != QMAX_OK) return result;
  if (read_total != file->bytes)
    return fail(error, QMAX_CONTRACT_MISMATCH, "Artifact changed while it was being verified");
  unsigned char digest[32];
  sha256_final(&ctx, digest);
  char actual[65];
  static const char digits[] = "0123456789abcdef";
  for (int i = 0; i < 32; ++i) {
    actual[i * 2] = digits[digest[i] >> 4];
    actual[i * 2 + 1] = digits[digest[i] & 0x0f];
  }
  actual[64] = '\0';
  if (memcmp(actual, file->sha256, 64) != 0)
    return fail(error, QMAX_CONTRACT_MISMATCH, "Artifact SHA-256 differs from the verified receipt");
  return QMAX_OK;
}

QMaxCode qmax_model_verify(const QMaxModelReceipt *receipt, QMaxError *error) {
  reset_error(error);
  QMaxCode result = schema(receipt, error);
  if (result != QMAX_OK) return result;
  for (size_t i = 0; i < receipt->file_count; ++i) {
    result = verify_file(&receipt->files[i], error);
    if (result != QMAX_OK) return result;
  }
  return fail(error, QMAX_OK, "");
}

/* ---------- runner contract ---------- */

static QMaxCode runner_contract(const QMaxModelRunner *runner,
                                const QMaxModelReceipt *receipt,
                                QMaxError *error) {
  if (!receipt) return fail(error, QMAX_INVALID_ARGUMENT, "Model receipt is required");
  if (!runner || !text_ok(runner->abi, 63) || strcmp(runner->abi, QMAX_MODEL_RUNNER_ABI) != 0)
    return fail(error, QMAX_CONTRACT_MISMATCH, "A runner with the exact reviewed ABI is required");
  if (strcmp(receipt->runner_abi, QMAX_MODEL_RUNNER_ABI) != 0)
    return fail(error, QMAX_CONTRACT_MISMATCH, "Receipt runner ABI does not match this adapter");
  if (!runner->open || !runner->tokenize || !runner->next_token || !runner->close)
    return fail(error, QMAX_CONTRACT_MISMATCH, "Runner is missing a required callback");
  return QMAX_OK;
}

static int opt_out_present(void) {
  const char *telemetry = getenv("MODULAR_TELEMETRY_ENABLED");
  const char *crash = getenv("MODULAR_CRASH_REPORTING_ENABLED");
  return telemetry && !strcmp(telemetry, "0") && crash && !strcmp(crash, "0");
}

/* ---------- UTF-8 streaming filter ---------- */

typedef struct {
  unsigned char bytes[4];
  size_t length;
  size_t needed;
} Utf8Filter;

static size_t expected_sequence(unsigned char lead) {
  if (lead < 0x80) return 1;
  if (lead >= 0xc2 && lead <= 0xdf) return 2;
  if (lead >= 0xe0 && lead <= 0xef) return 3;
  if (lead >= 0xf0 && lead <= 0xf4) return 4;
  return 0;
}

static int continuation_ok(unsigned char lead, size_t index, unsigned char byte) {
  if (index == 1) {
    if (lead == 0xe0) return byte >= 0xa0 && byte <= 0xbf;
    if (lead == 0xed) return byte >= 0x80 && byte <= 0x9f;
    if (lead == 0xf0) return byte >= 0x90 && byte <= 0xbf;
    if (lead == 0xf4) return byte >= 0x80 && byte <= 0x8f;
  }
  return byte >= 0x80 && byte <= 0xbf;
}

static size_t replacement(unsigned char *out) {
  out[0] = 0xef;
  out[1] = 0xbf;
  out[2] = 0xbd;
  return 3;
}

/* Writes valid UTF-8 only. Invalid, overlong, surrogate and truncated
 * sequences become U+FFFD; complete characters are never split across calls.
 * `out` must have room for `length * 3 + 3` bytes.
 */
static size_t utf8_feed(Utf8Filter *filter, const unsigned char *data,
                        size_t length, unsigned char *out) {
  size_t produced = 0;
  for (size_t i = 0; i < length;) {
    unsigned char byte = data[i];
    if (filter->length == 0) {
      size_t needed = expected_sequence(byte);
      if (needed == 0) {
        produced += replacement(out + produced);
        ++i;
        continue;
      }
      filter->bytes[0] = byte;
      filter->length = 1;
      filter->needed = needed;
      if (needed == 1) {
        out[produced++] = byte;
        filter->length = 0;
      }
      ++i;
      continue;
    }
    if (!continuation_ok(filter->bytes[0], filter->length, byte)) {
      produced += replacement(out + produced);
      filter->length = 0;
      continue;
    }
    filter->bytes[filter->length++] = byte;
    if (filter->length == filter->needed) {
      memcpy(out + produced, filter->bytes, filter->length);
      produced += filter->length;
      filter->length = 0;
    }
    ++i;
  }
  return produced;
}

static size_t utf8_flush(Utf8Filter *filter, unsigned char *out) {
  if (filter->length == 0) return 0;
  filter->length = 0;
  return replacement(out);
}

/* ---------- timing ---------- */

static double now_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0.0;
  return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

/* ---------- model handle ---------- */

struct QMaxModel {
  const QMaxModelRunner *runner;
  void *runner_state;
  uint32_t context_tokens;
  uint32_t max_output_tokens;
  atomic_int busy; /* 0 idle, 1 running, 2 cancelled. */
};

QMaxCode qmax_model_capability(const QMaxModelRunner *runner,
                               const QMaxModelReceipt *receipt,
                               int load_probe_passed,
                               QMaxModelCapability *out) {
  if (!out) return fail(NULL, QMAX_INVALID_ARGUMENT, "Capability output is required");
  memset(out, 0, sizeof(*out));
  QMaxError local;
  memset(&local, 0, sizeof(local));
  QMaxCode result = schema(receipt, &local);
  if (result == QMAX_OK) result = runner_contract(runner, receipt, &local);
  out->contract_ok = result == QMAX_OK ? 1 : 0;
  out->load_probe_passed = load_probe_passed ? 1 : 0;
  out->available = out->contract_ok && out->load_probe_passed;
  if (result == QMAX_OK) {
    copy_text(out->runner, sizeof(out->runner), receipt->runner_name);
    copy_text(out->backend, sizeof(out->backend), receipt->backend);
    out->context_tokens = receipt->context_tokens;
    out->max_output_tokens = receipt->max_output_tokens;
    if (!opt_out_present()) {
      out->available = 0;
      copy_text(out->reason, sizeof(out->reason), "MAX telemetry and crash-reporting opt-outs are required");
      return QMAX_OK;
    }
  } else {
    copy_text(out->reason, sizeof(out->reason), local.message);
    return result;
  }
  if (!out->available)
    copy_text(out->reason, sizeof(out->reason), "A real load probe has not passed");
  return QMAX_OK;
}

QMaxCode qmax_model_open(const QMaxModelRunner *runner,
                         const QMaxModelReceipt *receipt, QMaxModel **out,
                         QMaxError *error) {
  QMaxError local;
  memset(&local, 0, sizeof(local));
  if (!error) { error = &local; }
  if (out) *out = NULL;
  reset_error(error);
  if (!out) return fail(error, QMAX_INVALID_ARGUMENT, "Model output handle is required");
  QMaxCode result = schema(receipt, error);
  if (result != QMAX_OK) return result;
  result = runner_contract(runner, receipt, error);
  if (result != QMAX_OK) return result;
  if (!opt_out_present())
    return fail(error, QMAX_UNAVAILABLE, "MAX telemetry and crash-reporting opt-outs are required before runtime load");
  result = qmax_model_verify(receipt, error);
  if (result != QMAX_OK) return result;
  void *state = runner->open(receipt, error);
  if (!state) {
    if (error->code == QMAX_OK) error->code = QMAX_UNAVAILABLE;
    if (!error->message[0])
      copy_text(error->message, sizeof(error->message), "Vendor runner could not open the verified installation");
    return error->code;
  }
  QMaxModel *model = calloc(1, sizeof(*model));
  if (!model) {
    runner->close(state);
    return fail(error, QMAX_UNAVAILABLE, "Cannot allocate the model adapter state");
  }
  model->runner = runner;
  model->runner_state = state;
  model->context_tokens = receipt->context_tokens;
  model->max_output_tokens = receipt->max_output_tokens;
  atomic_init(&model->busy, 0);
  *out = model;
  return fail(error, QMAX_OK, "");
}

void qmax_model_cancel(QMaxModel *model) {
  if (model) {
    int expected = 1;
    atomic_compare_exchange_strong(&model->busy, &expected, 2);
  }
}

QMaxCode qmax_model_close(QMaxModel *model) {
  if (!model) return QMAX_OK;
  int expected = 0;
  if (!atomic_compare_exchange_strong(&model->busy, &expected, 1))
    return QMAX_BUSY;
  /* Keep the lease set: a racing close or generate must not reuse freed state. */
  if (model->runner_state && model->runner && model->runner->close)
    model->runner->close(model->runner_state);
  free(model);
  return QMAX_OK;
}

QMaxCode qmax_model_generate(QMaxModel *model, const QMaxModelRequest *request,
                             QMaxModelEmit emit, void *emit_context,
                             QMaxModelShouldStop should_stop,
                             void *stop_context,
                             QMaxModelPerformance *performance,
                             QMaxError *error) {
  QMaxError local;
  memset(&local, 0, sizeof(local));
  if (!error) { error = &local; }
  if (performance) {
    memset(performance, 0, sizeof(*performance));
    performance->status = 6;
  }
  reset_error(error);
  if (!model || !request || !emit) return fail(error, QMAX_INVALID_ARGUMENT, "Model, request and streaming sink are required");
  if (!request->prompt || request->prompt_bytes < 1 || request->prompt_bytes > QMAX_MODEL_MAX_PROMPT_BYTES)
    return fail(error, QMAX_INVALID_ARGUMENT, "Prompt is outside the bounded UTF-8 request size");
  if (request->max_tokens < 1 || request->max_tokens > model->max_output_tokens)
    return fail(error, QMAX_INVALID_ARGUMENT, "Requested output exceeds the verified output budget");
  if (!(request->temperature >= 0.0f && request->temperature <= 2.0f) ||
      !(request->top_p > 0.0f && request->top_p <= 1.0f))
    return fail(error, QMAX_INVALID_ARGUMENT, "Sampling parameters are outside the reviewed range");

  int expected = 0;
  if (!atomic_compare_exchange_strong(&model->busy, &expected, 1))
    return fail(error, QMAX_BUSY, "Generation is already in progress for this model");
#ifdef QMAX_MODEL_TEST_ADMISSION
  extern void qmax_model_test_admitted(QMaxModel *model);
  qmax_model_test_admitted(model);
#endif

  int32_t *tokens = malloc(sizeof(int32_t) * model->context_tokens);
  if (!tokens) {
    atomic_store(&model->busy, 0);
    return fail(error, QMAX_UNAVAILABLE, "Cannot allocate the bounded token buffer");
  }
  QMaxCode result = QMAX_RUNTIME_ERROR;
  const char *stage = "Prompt tokenization failed";
  size_t prompt_tokens = 0;
  uint32_t decoded = 0;
  int status = 0;
  double prefill_ms = 0.0, decode_ms = 0.0, first_ms = 0.0, max_gap_ms = 0.0;
  size_t streamed = 0;
  size_t total = 0;

  QMaxCode tokenized = model->runner->tokenize(
      model->runner_state, request->prompt, request->prompt_bytes, tokens,
      model->context_tokens, &prompt_tokens, error);
  if (tokenized != QMAX_OK) {
    result = tokenized == QMAX_CANCELLED ? QMAX_CANCELLED : tokenized;
    if (tokenized == QMAX_CANCELLED) status = 1;
    else status = 2;
    goto finished;
  }
  if (prompt_tokens < 1 || prompt_tokens > model->context_tokens) {
    result = fail(error, QMAX_CONTRACT_MISMATCH, "Tokenizer returned an out-of-range token count");
    status = 2;
    goto finished;
  }
  if (prompt_tokens >= model->context_tokens) {
    result = fail(error, QMAX_CONTRACT_MISMATCH, "Prompt does not fit the verified context");
    status = 2;
    goto finished;
  }
  total = prompt_tokens;
  if (request->max_tokens > model->context_tokens - total) {
    status = 5;
  }
  uint32_t budget = (uint32_t)(model->context_tokens - total);
  if (request->max_tokens < budget) budget = request->max_tokens;

  {
    const double started = now_ms();
    Utf8Filter filter;
    memset(&filter, 0, sizeof(filter));
    int complete = 0;
    for (uint32_t index = 0; index < budget; ++index) {
      if (should_stop && should_stop(stop_context)) {
        status = 1;
        result = QMAX_CANCELLED;
        fail(error, QMAX_CANCELLED, "Generation stopped before the next token");
        goto finished;
      }
      if (atomic_load_explicit(&model->busy, memory_order_relaxed) == 2) {
        status = 1;
        result = QMAX_CANCELLED;
        fail(error, QMAX_CANCELLED, "Generation cancelled at a token boundary");
        goto finished;
      }
      int32_t token = 0;
      char piece[QMAX_MODEL_MAX_PIECE_BYTES];
      size_t piece_bytes = 0;
      int end_of_generation = 0;
      const double call_started = now_ms();
      QMaxCode step = model->runner->next_token(
          model->runner_state, tokens, total, request->temperature,
          request->top_p, request->seed, &token, piece, sizeof(piece),
          &piece_bytes, &end_of_generation, error);
      const double call_ms = now_ms() - call_started;
      if (step != QMAX_OK) {
        status = step == QMAX_CANCELLED ? 1 : 2;
        result = step == QMAX_CANCELLED ? QMAX_CANCELLED : step;
        stage = "Runner decode step failed";
        goto finished;
      }
      if (piece_bytes > sizeof(piece)) {
        status = 2;
        result = fail(error, QMAX_CONTRACT_MISMATCH, "Runner returned an oversized token piece");
        goto finished;
      }
      decoded += 1;
      if (index == 0) {
        prefill_ms = call_ms;
        first_ms = now_ms() - started;
      } else {
        decode_ms += call_ms;
        if (call_ms > max_gap_ms) max_gap_ms = call_ms;
      }
      if (piece_bytes > 0) {
        unsigned char out[QMAX_MODEL_MAX_PIECE_BYTES * 3 + 4];
        size_t produced = utf8_feed(&filter, (const unsigned char *)piece,
                                    piece_bytes, out);
        if (produced > 0) {
          if (streamed > QMAX_MODEL_MAX_STREAM_BYTES - produced) {
            status = 2;
            result = fail(error, QMAX_CONTRACT_MISMATCH, "Streamed output exceeds the bounded response size");
            goto finished;
          }
          streamed += produced;
          if (!emit(emit_context, (const char *)out, produced)) {
            status = 4;
            result = QMAX_CANCELLED;
            fail(error, QMAX_CANCELLED, "Streaming sink stopped generation");
            goto finished;
          }
        }
      }
      tokens[total++] = token;
      if (end_of_generation) {
        complete = 1;
        break;
      }
      if (total >= model->context_tokens || index + 1 == budget) {
        if (status != 5) status = 3;
        complete = 1;
        break;
      }
    }
    if (complete) {
      unsigned char tail[4];
      size_t produced = utf8_flush(&filter, tail);
      if (produced > 0) {
        if (streamed > QMAX_MODEL_MAX_STREAM_BYTES - produced) {
          status = 2;
          result = fail(error, QMAX_CONTRACT_MISMATCH, "Streamed output exceeds the bounded response size");
          goto finished;
        }
        if (!emit(emit_context, (const char *)tail, produced)) {
          status = 4;
          result = QMAX_CANCELLED;
          fail(error, QMAX_CANCELLED, "Streaming sink stopped generation");
          goto finished;
        }
      }
      result = fail(error, QMAX_OK, "");
    } else {
      /* The output budget ended without EOG or a terminal condition. */
      status = 3;
      result = fail(error, QMAX_OK, "");
    }
  }

finished:
  if (performance) {
    performance->prompt_tokens = prompt_tokens <= model->context_tokens ? (uint32_t)prompt_tokens : 0;
    performance->decoded_tokens = decoded;
    performance->prefill_ms = prefill_ms;
    performance->decode_ms = decode_ms;
    performance->first_token_ms = first_ms;
    performance->max_gap_ms = max_gap_ms;
    performance->status = status;
    performance->cache_mode = 0;
  }
  if (status == 2) fail_keep(error, result, stage);
  free(tokens);
  atomic_store_explicit(&model->busy, 0, memory_order_release);
  return result;
}
