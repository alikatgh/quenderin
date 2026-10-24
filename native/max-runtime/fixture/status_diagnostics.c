/* Linked only into the public synthetic fixture, never the native bridge.
 * Keep vendor status details out of QMaxError and cap/flatten fixture logs.
 */
#include "max/c/common.h"
#include "max/c/model.h"

#include <stdio.h>

M_AsyncModel *__real_M_initModel(const M_RuntimeContext *,
                               const M_AsyncCompiledModel *,
                               const M_WeightsRegistry *, M_Status *);
void __real_M_waitForModel(M_AsyncModel *, M_Status *);

static void report_status(const char *stage, const M_Status *status) {
  if (!status || !M_isError(status)) return;
  const char *message = M_getError(status);
  fprintf(stderr, "MAX synthetic fixture SDK %s: ", stage);
  if (!message) {
    fputs("<no status message>\n", stderr);
    return;
  }
  size_t i = 0;
  for (; i < 1024 && message[i]; ++i) {
    unsigned char byte = (unsigned char)message[i];
    fputc(byte >= 32 && byte <= 126 ? byte : ' ', stderr);
  }
  if (i == 1024) fputs(" [truncated]", stderr);
  fputc('\n', stderr);
}

M_AsyncModel *__wrap_M_initModel(const M_RuntimeContext *context,
                               const M_AsyncCompiledModel *compiled,
                               const M_WeightsRegistry *weights,
                               M_Status *status) {
  M_AsyncModel *model = __real_M_initModel(context, compiled, weights, status);
  report_status("M_initModel", status);
  return model;
}

void __wrap_M_waitForModel(M_AsyncModel *model, M_Status *status) {
  __real_M_waitForModel(model, status);
  report_status("M_waitForModel", status);
}
