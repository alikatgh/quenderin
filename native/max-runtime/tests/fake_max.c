#define _POSIX_C_SOURCE 200809L
#include "fake_max.h"
#include "quenderin_max.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct Handle { int kind, error; const void *data; int64_t shape[8], rank; };
static int live, step, fail_at, bad_output;
static int event(M_Status *status) {
  int fail = ++step == fail_at;
  if (status) status->error = fail;
  return fail;
}
static struct Handle *make(int kind, M_Status *status) {
  if (event(status)) return NULL;
  struct Handle *handle = calloc(1, sizeof(*handle));
  assert(handle); handle->kind = kind; ++live; return handle;
}
static void drop(struct Handle *handle) {
  assert(handle && live > 0);
  if (handle->kind == 9) free((void *)handle->data);
  --live; free(handle);
}
M_Status *M_newStatus(void) { return make(1, NULL); }
int M_isError(const M_Status *status) { assert(status); return status->error; }
const char *M_getError(const M_Status *status) {
  assert(status && status->error);
  static char message[2049];
  const char prefix[] = "injected failure\n\t\033";
  memset(message, 'x', sizeof(message) - 1);
  memcpy(message, prefix, sizeof(prefix) - 1);
  message[sizeof(message) - 1] = '\0';
  return message;
}
const char *M_version(void) { return "fake-not-MAX"; }
void M_freeStatus(M_Status *v) { drop(v); }
M_RuntimeConfig *M_newRuntimeConfig(void) { return make(2, NULL); }
void M_runtimeConfigAddDevice(M_RuntimeConfig *a, M_Device *b) { assert(a && b); }
void M_freeRuntimeConfig(M_RuntimeConfig *v) { drop(v); }
M_RuntimeContext *M_newRuntimeContext(const M_RuntimeConfig *c, M_Status *s) { assert(c); return make(3, s); }
void M_freeRuntimeContext(M_RuntimeContext *v) { drop(v); }
M_Device *M_newDevice(M_DeviceType type, int id, M_Status *s) { assert(type == M_HOST && id == 0); return make(4, s); }
int M_isHostDevice(const M_Device *v) { assert(v); return bad_output != 3; }
void M_freeDevice(M_Device *v) { drop(v); }
M_CompileConfig *M_newCompileConfig(void) { return make(5, NULL); }
void M_setModelPath(M_CompileConfig *c, const char *p) { assert(c && p); }
M_AsyncCompiledModel *M_compileModelSync(const M_RuntimeContext *c, M_CompileConfig **config, M_Status *s) {
  assert(c && config && *config); drop(*config); *config = NULL; return make(6, s);
}
void M_freeCompileConfig(M_CompileConfig *v) { drop(v); }
void M_freeCompiledModel(M_AsyncCompiledModel *v) { drop(v); }
M_WeightsRegistry *M_newWeightsRegistry(const char **names, const void **data, size_t count, M_Status *s) {
  assert(names && !strcmp(names[0], "weight") && data && count == 1);
  M_WeightsRegistry *v = make(7, s); if (v) v->data = data[0]; return v;
}
void M_freeWeightsRegistry(M_WeightsRegistry *v) { drop(v); }
M_AsyncModel *M_initModel(const M_RuntimeContext *c, const M_AsyncCompiledModel *m, const M_WeightsRegistry *w, M_Status *s) {
  assert(c && m && w); M_AsyncModel *v = make(8, s); if (v) v->data = w->data; return v;
}
void M_waitForModel(M_AsyncModel *v, M_Status *s) { assert(v); event(s); }
void M_freeModel(M_AsyncModel *v) { drop(v); }
M_TensorSpec *M_newTensorSpec(const int64_t *shape, int64_t rank, M_Dtype dtype, const char *name, const M_Device *device) {
  assert(rank <= 8 && dtype == M_FLOAT32 && name && device);
  M_TensorSpec *v = make(10, NULL); if (v) { memcpy(v->shape, shape, (size_t)rank * sizeof(int64_t)); v->rank = rank; } return v;
}
void M_freeTensorSpec(M_TensorSpec *v) { drop(v); }
M_AsyncTensorMap *M_newAsyncTensorMap(const M_RuntimeContext *c) { assert(c); return make(11, NULL); }
void M_borrowTensorInto(M_AsyncTensorMap *map, void *data, const M_TensorSpec *spec, M_Status *s) {
  assert(map && data && spec); map->data = data; event(s);
}
M_AsyncTensorMap *M_executeModelSync(const M_RuntimeContext *c, M_AsyncModel *model, M_AsyncTensorMap *inputs, M_Status *s) {
  assert(c && model && inputs); M_AsyncTensorMap *map = make(9, s);
  if (map) {
    float *data = malloc(4 * sizeof(float)); assert(data);
    for (int i = 0; i < 4; ++i) data[i] = ((const float *)inputs->data)[i] * ((const float *)model->data)[i];
    map->data = data;
  }
  return map;
}
M_AsyncTensor *M_getTensorByNameFrom(M_AsyncTensorMap *map, const char *name, M_Status *s) {
  assert(map && !strcmp(name, "output0")); M_AsyncTensor *v = make(12, s); if (v) v->data = map->data; return v;
}
M_TensorSpec *M_getTensorSpec(const M_AsyncTensor *t) {
  assert(t); M_TensorSpec *v = make(10, NULL); if (v) { v->rank = 1; v->shape[0] = bad_output == 1 ? 3 : 4; } return v;
}
M_Device *M_getTensorDevice(const M_AsyncTensor *t) { assert(t); return make(4, NULL); }
M_Dtype M_getTensorType(const M_AsyncTensor *t) { assert(t); return bad_output == 2 ? M_INT32 : M_FLOAT32; }
size_t M_getTensorNumElements(const M_AsyncTensor *t) { assert(t); return bad_output == 5 ? 3 : 4; }
int M_isDynamicRanked(const M_TensorSpec *s) { assert(s); return bad_output == 6; }
int64_t M_getRank(const M_TensorSpec *s) { return s->rank; }
int64_t M_getDimAt(const M_TensorSpec *s, size_t i) { return s->shape[i]; }
const void *M_getTensorData(const M_AsyncTensor *t) { assert(t); return bad_output == 4 ? NULL : t->data; }
void M_freeTensor(M_AsyncTensor *v) { drop(v); }
void M_freeAsyncTensorMap(M_AsyncTensorMap *v) { drop(v); }

static int stop_on_second(void *context) { return ++*(int *)context == 2; }
static QMaxGraphSpec graph(const char *path, float *weights) {
  static const int64_t shape[] = {4};
  QMaxGraphSpec spec = {.mef_path = path, .input = {"input0", shape, 1},
    .output = {"output0", shape, 1}, .weight_name = "weight", .weight_data = weights, .weight_elements = 4};
  return spec;
}
int main(int argc, char **argv) {
  assert(argc == 2);
  float weights[] = {2, 3, 4, 5}, input[] = {1, 2, 3, 4};
  QMaxGraphSpec spec = graph(argv[1], weights);
  QMaxError error;
  for (int injection = 0; injection <= 19; ++injection) {
    fail_at = injection; step = 0;
    QMaxSession *session = NULL;
    float output[] = {-1, -1, -1, -1};
    QMaxCode result = qmax_open(&spec, &session, &error);
    if (result == QMAX_OK) result = qmax_execute(session, input, 4, output, 4, NULL, NULL, &error);
    if (!injection || injection > step) { assert(result == QMAX_OK && output[3] == 20); }
    else { assert(result != QMAX_OK && output[0] == -1); }
    if (injection == 8 || injection == 9) {
      assert(result == QMAX_RUNTIME_ERROR && !strcmp(error.message, "Cannot initialize MAX graph"));
    }
    qmax_close(session); assert(live == 0);
  }
  fail_at = 0;
  for (bad_output = 1; bad_output <= 6; ++bad_output) {
    QMaxSession *session = NULL; float output[] = {-1, -1, -1, -1};
    assert(qmax_open(&spec, &session, &error) == QMAX_OK);
    assert(qmax_execute(session, input, 4, output, 4, NULL, NULL, &error) != QMAX_OK && output[0] == -1);
    qmax_close(session); assert(live == 0);
  }
  bad_output = 0;
  QMaxSession *session = NULL; float output[] = {-1, -1, -1, -1};
  assert(qmax_open(&spec, &session, &error) == QMAX_OK);
  memset(weights, 0, sizeof(weights));
  assert(qmax_execute(session, input, 4, output, 4, NULL, NULL, &error) == QMAX_OK && output[3] == 20);
  int stops = 0; output[0] = -1;
  assert(qmax_execute(session, input, 4, output, 4, stop_on_second, &stops, &error) == QMAX_CANCELLED && output[0] == -1);
  assert(qmax_execute(session, input, 3, output, 4, NULL, NULL, &error) == QMAX_INVALID_ARGUMENT);
  assert(qmax_execute(session, input, 4, input, 4, NULL, NULL, &error) == QMAX_INVALID_ARGUMENT);
  qmax_close(session); assert(live == 0);
  session = NULL; spec.mef_path = "/missing/graph.mef";
  assert(qmax_open(&spec, &session, &error) == QMAX_INVALID_ARGUMENT && !session);
  qmax_close(NULL);
  puts("C ABI double: lifecycle, injected failures, CPU/shape/dtype checks, borrowed memory and step-stop passed; real MAX not executed");
  return 0;
}
