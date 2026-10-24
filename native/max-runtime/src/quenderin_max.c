/* MAX lifecycle follows Modular's weights_example.c at revision
 * 527d069ee11a41ac5320af1f9402db0a66b2b868. See ../NOTICE.md.
 */
#define _POSIX_C_SOURCE 200809L
#include "quenderin_max.h"
#include "max/c/common.h"
#include "max/c/context.h"
#include "max/c/device.h"
#include "max/c/model.h"
#include "max/c/tensor.h"
#include "max/c/weights.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

struct QMaxSession {
  M_Status *status;
  M_RuntimeConfig *config;
  M_RuntimeContext *context;
  M_Device *host;
  M_CompileConfig *compile;
  M_AsyncCompiledModel *compiled;
  M_WeightsRegistry *weights;
  M_AsyncModel *model;
  M_TensorSpec *input_spec;
  float *weight_data;
  char output_name[128];
  int64_t output_shape[QMAX_MAX_RANK];
  size_t output_rank, input_elements, output_elements;
};

static QMaxCode fail(QMaxError *error, QMaxCode code, const char *message) {
  if (error) {
    error->code = code;
    snprintf(error->message, sizeof(error->message), "%s", message);
  }
  return code;
}

static QMaxCode runtime_error(QMaxSession *session, QMaxError *error,
                              const char *stage) {
  /* Deliberately omit arbitrary vendor diagnostics (and paths/input data)
   * from an API that may eventually be surfaced in a native application.
   */
  (void)session;
  return fail(error, QMAX_RUNTIME_ERROR, stage);
}

static int valid_name(const char *name) {
  return name && name[0] && strnlen(name, 128) < 128;
}

static size_t elements(const QMaxTensorSpec *spec) {
  if (!spec || !valid_name(spec->name) || !spec->shape || !spec->rank ||
      spec->rank > QMAX_MAX_RANK) return 0;
  size_t count = 1;
  for (size_t i = 0; i < spec->rank; ++i) {
    if (spec->shape[i] <= 0 || (uint64_t)spec->shape[i] > QMAX_MAX_ELEMENTS ||
        count > QMAX_MAX_ELEMENTS / (size_t)spec->shape[i]) return 0;
    count *= (size_t)spec->shape[i];
  }
  return count;
}

static int opt_out_present(void) {
  const char *telemetry = getenv("MODULAR_TELEMETRY_ENABLED");
  const char *crash = getenv("MODULAR_CRASH_REPORTING_ENABLED");
  return telemetry && !strcmp(telemetry, "0") && crash && !strcmp(crash, "0");
}

static int valid_mef_path(const char *path) {
  if (!path) return 0;
  size_t length = strnlen(path, 4096);
  if (length < 5 || length == 4096 || strcmp(path + length - 4, ".mef")) return 0;
  struct stat info;
  /* Reject links/empty/oversized files. Artifact provenance and immutability
   * remain the caller's responsibility: MAX opens the path itself.
   */
  if (lstat(path, &info) || !S_ISREG(info.st_mode) || info.st_size < 4 ||
      info.st_size > 64 * 1024 * 1024) return 0;
  FILE *file = fopen(path, "rb");
  if (!file) return 0;
  char magic[4];
  size_t read = fread(magic, 1, sizeof(magic), file);
  fclose(file);
  return read == 4 && memcmp(magic, "GGUF", 4);
}

void qmax_close(QMaxSession *session) {
  if (!session) return;
  if (session->input_spec) M_freeTensorSpec(session->input_spec);
  if (session->model) M_freeModel(session->model);
  if (session->weights) M_freeWeightsRegistry(session->weights);
  if (session->compiled) M_freeCompiledModel(session->compiled);
  /* M_compileModelSync consumes and nulls compile, even on failure. */
  if (session->compile) M_freeCompileConfig(session->compile);
  if (session->host) M_freeDevice(session->host);
  if (session->context) M_freeRuntimeContext(session->context);
  if (session->config) M_freeRuntimeConfig(session->config);
  if (session->status) M_freeStatus(session->status);
  free(session->weight_data);
  free(session);
}

QMaxCode qmax_open(const QMaxGraphSpec *spec, QMaxSession **out,
                   QMaxError *error) {
  if (out) *out = NULL;
  if (!out || !spec) return fail(error, QMAX_INVALID_ARGUMENT, "Graph and output session are required");
  size_t input_count = elements(&spec->input), output_count = elements(&spec->output);
  if (!input_count || !output_count || !valid_mef_path(spec->mef_path) ||
      spec->weight_elements > QMAX_MAX_ELEMENTS ||
      (spec->weight_elements && (!spec->weight_data || !valid_name(spec->weight_name))) ||
      (!spec->weight_elements && (spec->weight_data || spec->weight_name))) {
    return fail(error, QMAX_INVALID_ARGUMENT, "Invalid MEF path or bounded float32 tensor contract");
  }
  if (!opt_out_present()) return fail(error, QMAX_UNAVAILABLE, "MAX telemetry and crash-reporting opt-outs are required before runtime load");
  QMaxSession *session = calloc(1, sizeof(*session));
  if (!session) return fail(error, QMAX_UNAVAILABLE, "Cannot allocate graph session");
  QMaxCode result = QMAX_RUNTIME_ERROR;
  const char *stage = "Cannot allocate MAX status";
  session->status = M_newStatus();
  if (!session->status) goto failed;
  session->input_elements = input_count;
  session->output_elements = output_count;
  session->output_rank = spec->output.rank;
  memcpy(session->output_shape, spec->output.shape, spec->output.rank * sizeof(int64_t));
  memcpy(session->output_name, spec->output.name, strlen(spec->output.name) + 1);

  stage = "Cannot allocate MAX runtime configuration";
  session->config = M_newRuntimeConfig();
  if (!session->config) goto failed;
  stage = "Cannot create MAX runtime context";
  session->context = M_newRuntimeContext(session->config, session->status);
  if (!session->context || M_isError(session->status)) goto failed;
  stage = "Cannot create MAX CPU device";
  session->host = M_newDevice(M_HOST, 0, session->status);
  if (!session->host || M_isError(session->status)) goto failed;

  stage = "Cannot allocate MAX compile configuration";
  session->compile = M_newCompileConfig();
  if (!session->compile) goto failed;
  M_setModelPath(session->compile, spec->mef_path);
  stage = "MAX MEF compilation failed";
  session->compiled = M_compileModelSync(session->context, &session->compile, session->status);
  if (!session->compiled || M_isError(session->status)) goto failed;
  if (spec->weight_elements) {
    stage = "Cannot allocate external graph weight";
    session->weight_data = malloc(spec->weight_elements * sizeof(float));
    if (!session->weight_data) goto failed;
    memcpy(session->weight_data, spec->weight_data, spec->weight_elements * sizeof(float));
    const char *names[] = {spec->weight_name};
    const void *data[] = {session->weight_data};
    stage = "Cannot create MAX weight registry";
    session->weights = M_newWeightsRegistry(names, data, 1, session->status);
    if (!session->weights || M_isError(session->status)) goto failed;
  }
  stage = "Cannot initialize MAX graph";
  session->model = M_initModel(session->context, session->compiled, session->weights, session->status);
  if (!session->model || M_isError(session->status)) goto failed;
  M_waitForModel(session->model, session->status);
  if (M_isError(session->status)) goto failed;
  stage = "Cannot allocate MAX input tensor specification";
  session->input_spec = M_newTensorSpec(spec->input.shape, (int64_t)spec->input.rank,
                                      M_FLOAT32, spec->input.name, session->host);
  if (!session->input_spec) goto failed;
  *out = session;
  return fail(error, QMAX_OK, "");
failed:
  result = runtime_error(session, error, stage);
  qmax_close(session);
  return result;
}

QMaxCode qmax_execute(QMaxSession *session, const float *input,
                      size_t input_count, float *output, size_t output_count,
                      QMaxShouldStop should_stop, void *stop_context,
                      QMaxError *error) {
  if (!session || !input || !output || input_count != session->input_elements ||
      output_count != session->output_elements) {
    return fail(error, QMAX_INVALID_ARGUMENT, "Input/output buffers must match the graph contract");
  }
  uintptr_t in_start = (uintptr_t)input, out_start = (uintptr_t)output;
  size_t in_bytes = input_count * sizeof(float), out_bytes = output_count * sizeof(float);
  if (in_start > UINTPTR_MAX - in_bytes || out_start > UINTPTR_MAX - out_bytes ||
      (in_start < out_start + out_bytes && out_start < in_start + in_bytes)) {
    return fail(error, QMAX_INVALID_ARGUMENT, "Input and output buffers must not overlap");
  }
  if (should_stop && should_stop(stop_context)) return fail(error, QMAX_CANCELLED, "Stopped before graph execution");
  M_AsyncTensorMap *inputs = NULL, *outputs = NULL;
  M_AsyncTensor *tensor = NULL;
  M_TensorSpec *spec = NULL;
  M_Device *device = NULL;
  QMaxCode result = QMAX_RUNTIME_ERROR;
  const char *stage = "Cannot allocate MAX input map";
  inputs = M_newAsyncTensorMap(session->context);
  if (!inputs) goto finished;
  stage = "MAX input tensor construction failed";
  M_borrowTensorInto(inputs, (void *)input, session->input_spec, session->status);
  if (M_isError(session->status)) goto finished;
  stage = "MAX graph execution failed";
  outputs = M_executeModelSync(session->context, session->model, inputs, session->status);
  if (!outputs || M_isError(session->status)) goto finished;
  stage = "MAX graph output is missing";
  tensor = M_getTensorByNameFrom(outputs, session->output_name, session->status);
  if (!tensor || M_isError(session->status)) goto finished;
  spec = M_getTensorSpec(tensor);
  device = M_getTensorDevice(tensor);
  if (!spec || !device || M_getTensorType(tensor) != M_FLOAT32 ||
      M_getTensorNumElements(tensor) != output_count || !M_isHostDevice(device) ||
      M_isDynamicRanked(spec) || M_getRank(spec) != (int64_t)session->output_rank) {
    result = fail(error, QMAX_CONTRACT_MISMATCH, "MAX output must match the CPU float32 tensor contract");
    goto finished;
  }
  for (size_t i = 0; i < session->output_rank; ++i) {
    if (M_getDimAt(spec, i) != session->output_shape[i]) {
      result = fail(error, QMAX_CONTRACT_MISMATCH, "MAX output shape differs from the graph contract");
      goto finished;
    }
  }
  const void *data = M_getTensorData(tensor);
  if (!data) { stage = "MAX output buffer is unavailable"; goto finished; }
  if (should_stop && should_stop(stop_context)) {
    result = fail(error, QMAX_CANCELLED, "Stopped after the synchronous graph step");
    goto finished;
  }
  memcpy(output, data, out_bytes);
  result = fail(error, QMAX_OK, "");
finished:
  if (device) M_freeDevice(device);
  if (spec) M_freeTensorSpec(spec);
  if (tensor) M_freeTensor(tensor);
  if (outputs) M_freeAsyncTensorMap(outputs);
  if (inputs) M_freeAsyncTensorMap(inputs);
  if (result == QMAX_RUNTIME_ERROR) runtime_error(session, error, stage);
  return result;
}

const char *qmax_runtime_version(void) { return M_version(); }
