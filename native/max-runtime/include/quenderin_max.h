/* Quenderin's deliberately small MAX tensor-graph bridge.
 * This is not a tokenizer, GGUF loader, or autoregressive language model API.
 */
#ifndef QUENDERIN_MAX_H
#define QUENDERIN_MAX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { QMAX_MAX_RANK = 8, QMAX_MAX_ELEMENTS = 1048576 };
typedef enum {
  QMAX_OK = 0,
  QMAX_INVALID_ARGUMENT = 1,
  QMAX_UNAVAILABLE = 2,
  QMAX_RUNTIME_ERROR = 3,
  QMAX_CANCELLED = 4,
  QMAX_CONTRACT_MISMATCH = 5
} QMaxCode;

typedef struct {
  QMaxCode code;
  /* Bounded diagnostic; never contains tensor contents. */
  char message[256];
} QMaxError;

typedef struct {
  const char *name;
  const int64_t *shape;
  size_t rank;
} QMaxTensorSpec;

typedef struct {
  const char *mef_path;
  QMaxTensorSpec input;
  QMaxTensorSpec output;
  /* Optional single external float32 weight. The graph's reviewed contract
   * must establish its exact byte size: MAX's registry API takes no length.
   * Data is copied by open and retained until the model has been destroyed.
   */
  const char *weight_name;
  const float *weight_data;
  size_t weight_elements;
} QMaxGraphSpec;

typedef struct QMaxSession QMaxSession;
typedef int (*QMaxShouldStop)(void *context);

/* Opens a trusted, provenance-verified MEF graph on CPU only. Set both
 * MODULAR_TELEMETRY_ENABLED=0 and MODULAR_CRASH_REPORTING_ENABLED=0 before
 * loading libmax or importing MAX. No GGUF file may be supplied as a MEF.
 * A caller must supervise this synchronous call with an OS process deadline.
 * Sessions are serial and must not be called or closed concurrently.
 */
QMaxCode qmax_open(const QMaxGraphSpec *spec, QMaxSession **session,
                   QMaxError *error);

/* Executes one bounded-size float32 input/output graph. Buffers remain owned
 * by the caller and must not overlap or change during execution. Output is
 * committed only after a complete, CPU/shape/dtype-checked result. Stop is
 * checked before and after this synchronous step; MAX offers no C API to
 * interrupt the in-flight call. This is not token-stream cancellation.
 */
QMaxCode qmax_execute(QMaxSession *session, const float *input,
                      size_t input_elements, float *output,
                      size_t output_elements, QMaxShouldStop should_stop,
                      void *stop_context, QMaxError *error);

void qmax_close(QMaxSession *session);
const char *qmax_runtime_version(void);

#ifdef __cplusplus
}
#endif
#endif
