/* Deterministic in-process runner double. No MAX headers, runtime or weights. */
#ifndef FAKE_MODEL_RUNNER_H
#define FAKE_MODEL_RUNNER_H

#include "quenderin_max_model.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  const char *bytes;
  size_t length;
  int end_of_generation;
} FakePiece;

const QMaxModelRunner *fake_model_runner(void);
/* fail_at is the 1-based decode step that fails (0 = never).
 * bad_piece reports a piece larger than the supplied capacity (1 = yes).
 * open_fails: 1 = NULL with a message, 2 = NULL without a message.
 * zero_prompt makes tokenize return success with zero tokens.
 * end_at is an extra 0-based end-of-generation step (-1 = script only).
 * Resets the default script, flood mode and block gate.
 */
void fake_model_reset(int fail_at, int bad_piece, int open_fails,
                      int zero_prompt, int end_at);
void fake_model_script(const FakePiece *pieces, size_t count);
void fake_model_flood(int enabled);
void fake_model_block(int enabled);
void fake_model_wait_entered(void);
void fake_model_release(void);
int fake_model_live(void);
int fake_model_steps(void);
int fake_model_closed(void);

#ifdef __cplusplus
}
#endif
#endif
