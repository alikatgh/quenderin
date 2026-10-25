/* Deterministic runner double for the portable model adapter. */
#define _POSIX_C_SOURCE 200809L
#include "fake_model_runner.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  int steps;
} FakeRunner;

static const FakePiece kDefault[] = {
    {"he", 2, 0}, {"llo", 3, 0}, {" ", 1, 0},
    {"\xc3", 1, 0}, {"\xa9", 1, 0}, {"!", 1, 1},
};
static const size_t kDefaultLength = sizeof(kDefault) / sizeof(kDefault[0]);
static const FakePiece *script = kDefault;
static size_t script_length = sizeof(kDefault) / sizeof(kDefault[0]);

static int live;
static int fail_at;
static int bad_piece;
static int open_fails;
static int zero_prompt;
static int end_at = -1;
static int flood;

static pthread_mutex_t gate_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_cond = PTHREAD_COND_INITIALIZER;
static int block_first;
static int entered;
static int released;

void fake_model_reset(int fail_step, int oversized, int open_failure,
                      int empty_prompt, int end_step) {
  fail_at = fail_step;
  bad_piece = oversized;
  open_fails = open_failure;
  zero_prompt = empty_prompt;
  end_at = end_step;
  script = kDefault;
  script_length = kDefaultLength;
  flood = 0;
  block_first = 0;
  entered = 0;
  released = 0;
}

void fake_model_script(const FakePiece *pieces, size_t count) {
  if (!pieces || count < 1) return;
  script = pieces;
  script_length = count;
}

void fake_model_flood(int enabled) { flood = enabled; }

void fake_model_block(int enabled) {
  pthread_mutex_lock(&gate_mutex);
  block_first = enabled;
  entered = 0;
  released = 0;
  pthread_mutex_unlock(&gate_mutex);
}

void fake_model_wait_entered(void) {
  pthread_mutex_lock(&gate_mutex);
  while (!entered) pthread_cond_wait(&gate_cond, &gate_mutex);
  pthread_mutex_unlock(&gate_mutex);
}

void fake_model_release(void) {
  pthread_mutex_lock(&gate_mutex);
  released = 1;
  pthread_cond_broadcast(&gate_cond);
  pthread_mutex_unlock(&gate_mutex);
}

int fake_model_live(void) { return live; }
int fake_model_closed(void) { return live == 0; }
int fake_model_steps(void) { return (int)script_length; }

static void *fake_open(const QMaxModelReceipt *receipt, QMaxError *error) {
  if (!receipt) return NULL;
  if (open_fails == 1) {
    if (error) {
      error->code = QMAX_UNAVAILABLE;
      snprintf(error->message, sizeof(error->message), "injected runner open failure");
    }
    return NULL;
  }
  if (open_fails == 2) return NULL;
  FakeRunner *runner = calloc(1, sizeof(*runner));
  if (!runner) return NULL;
  ++live;
  return runner;
}

static QMaxCode fake_tokenize(void *state, const char *utf8, size_t bytes,
                              int32_t *tokens, size_t capacity, size_t *count,
                              QMaxError *error) {
  (void)error;
  if (!state || !utf8 || !tokens || !count || bytes < 1) return QMAX_INVALID_ARGUMENT;
  ((FakeRunner *)state)->steps = 0;
  if (zero_prompt) {
    *count = 0;
    return QMAX_OK;
  }
  if (bytes > capacity) return QMAX_CONTRACT_MISMATCH;
  for (size_t i = 0; i < bytes; ++i) tokens[i] = (int32_t)(unsigned char)utf8[i];
  *count = bytes;
  return QMAX_OK;
}

static QMaxCode fake_next(void *state, const int32_t *tokens, size_t count,
                          float temperature, float top_p, uint32_t seed,
                          int32_t *token, char *piece, size_t capacity,
                          size_t *piece_bytes, int *end_of_generation,
                          QMaxError *error) {
  FakeRunner *runner = state;
  if (!runner || !tokens || !token || !piece || !piece_bytes || !end_of_generation)
    return QMAX_INVALID_ARGUMENT;
  (void)temperature;
  (void)top_p;
  (void)seed;
  (void)count;
  int step = runner->steps++;
  if (step == 0 && block_first) {
    pthread_mutex_lock(&gate_mutex);
    entered = 1;
    pthread_cond_broadcast(&gate_cond);
    while (!released) pthread_cond_wait(&gate_cond, &gate_mutex);
    block_first = 0;
    pthread_mutex_unlock(&gate_mutex);
  }
  if (fail_at > 0 && step + 1 == fail_at) {
    if (error) {
      error->code = QMAX_RUNTIME_ERROR;
      snprintf(error->message, sizeof(error->message), "injected runner failure");
    }
    return QMAX_RUNTIME_ERROR;
  }
  if (bad_piece) {
    *piece_bytes = capacity + 1;
    *end_of_generation = 0;
    *token = 100;
    return QMAX_OK;
  }
  if (flood) {
    if (capacity < QMAX_MODEL_MAX_PIECE_BYTES) return QMAX_CONTRACT_MISMATCH;
    memset(piece, 'a', QMAX_MODEL_MAX_PIECE_BYTES);
    *piece_bytes = QMAX_MODEL_MAX_PIECE_BYTES;
    *token = 200 + (int32_t)step;
    *end_of_generation = 0;
    return QMAX_OK;
  }
  if (step >= (int)script_length) return QMAX_CONTRACT_MISMATCH;
  const FakePiece *current = &script[step];
  if (current->length > capacity) return QMAX_CONTRACT_MISMATCH;
  memcpy(piece, current->bytes, current->length);
  *piece_bytes = current->length;
  *token = 100 + (int32_t)step;
  *end_of_generation = current->end_of_generation || (step == end_at) ? 1 : 0;
  return QMAX_OK;
}

static void fake_close(void *state) {
  free(state);
  --live;
}

static const QMaxModelRunner kRunner = {
    .abi = QMAX_MODEL_RUNNER_ABI,
    .open = fake_open,
    .tokenize = fake_tokenize,
    .next_token = fake_next,
    .close = fake_close,
};

const QMaxModelRunner *fake_model_runner(void) { return &kRunner; }
