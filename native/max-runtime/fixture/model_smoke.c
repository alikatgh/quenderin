/* Host fixture for the portable MAX model-adapter boundary.
 * Uses inert files and a fake runner; no MAX runtime, weights or device.
 */
#define _POSIX_C_SOURCE 200809L
#include "fake_model_runner.h"
#include "quenderin_max_model.h"

#ifdef NDEBUG
#error "This fixture relies on assert(); do not build with NDEBUG"
#endif

#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char kMef[] = "MEF synthetic graph\n";
static const char kTokenizer[] = "tokenizer synthetic\n";
static const char kVector[] = "abc";
static const char kMefSha[] =
    "dbea4dafdb6a050bbf8fe890fd18b2a21d9772c175504c64c045bac139d7c63b";
static const char kTokenizerSha[] =
    "be5534c1f3fef78cec5aa03baeb5298b05b1e59e0f800e1e15c2587aa93ddb26";
static const char kVectorSha[] =
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
static const char kBulkSha[] =
    "72a2f8d2643328a2e03dcb1b66fdc6610b95ba3019d88d8849ce060d0be634ce";

static const FakePiece kThreeFourByte[] = {
    {"\xe2\x82", 2, 0}, {"\xac", 1, 0}, {"\xf0\x9f", 2, 0},
    {"\x98\x80", 2, 0}, {"!", 1, 1},
};
static const FakePiece kOverlong[] = {
    {"\xe0\x80", 2, 0}, {"\x80", 1, 0}, {"!", 1, 1},
};
static const FakePiece kSurrogate[] = {
    {"\xed\xa0\x80", 3, 0}, {"!", 1, 1},
};
static const FakePiece kTruncated[] = {{"\xe2\x82", 2, 1}};

typedef struct {
  char text[512];
  size_t length;
  int calls;
  int discard;
  int abort_after;
  int cancel_after;
  QMaxModel *cancel_model;
  QMaxModel *busy_model;
  QMaxModel *close_model;
  int busy_code;
  QMaxCode close_code;
} Sink;

typedef struct {
  QMaxModel *model;
  QMaxModelRequest request;
  Sink sink;
  QMaxCode result;
} ThreadRun;

static void join(char *out, size_t capacity, const char *directory,
                 const char *name) {
  int written = snprintf(out, capacity, "%s/%s", directory, name);
  assert(written > 0 && (size_t)written < capacity);
}

static void write_file(const char *path, const char *content, size_t bytes) {
  FILE *stream = fopen(path, "wb");
  assert(stream);
  assert(fwrite(content, 1, bytes, stream) == bytes);
  assert(fclose(stream) == 0);
}

static void expect_no_path(const QMaxError *error) {
  assert(error);
  assert(strchr(error->message, '/') == NULL);
  assert(strlen(error->message) < sizeof(error->message));
}

static void expect_text(const Sink *sink, const char *expected) {
  assert(sink->length == strlen(expected));
  assert(memcmp(sink->text, expected, sink->length) == 0);
}

static int sink_emit(void *context, const char *utf8, size_t bytes) {
  Sink *sink = context;
  if (sink->discard) {
    sink->length += bytes;
  } else {
    assert(sink->length + bytes <= sizeof(sink->text));
    memcpy(sink->text + sink->length, utf8, bytes);
    sink->length += bytes;
  }
  sink->calls += 1;
  if (sink->busy_model) {
    QMaxModelRequest nested = {.prompt = "x", .prompt_bytes = 1, .max_tokens = 1,
                               .temperature = 0.0f, .top_p = 1.0f, .seed = 0};
    QMaxError error;
    sink->busy_code = qmax_model_generate(sink->busy_model, &nested, sink_emit,
                                          sink, NULL, NULL, NULL, &error);
  }
  if (sink->close_model) sink->close_code = qmax_model_close(sink->close_model);
  if (sink->abort_after > 0 && sink->calls >= sink->abort_after) return 0;
  if (sink->cancel_after > 0 && sink->calls >= sink->cancel_after)
    qmax_model_cancel(sink->cancel_model);
  return 1;
}

static int stop_immediately(void *context) {
  (void)context;
  return 1;
}

static void *thread_generate(void *argument) {
  ThreadRun *run = argument;
  run->result = qmax_model_generate(run->model, &run->request, sink_emit,
                                    &run->sink, NULL, NULL, NULL, NULL);
  return NULL;
}

static QMaxModelRequest request(const char *prompt, uint32_t max_tokens) {
  QMaxModelRequest value = {.prompt = prompt,
                            .prompt_bytes = strlen(prompt),
                            .max_tokens = max_tokens,
                            .temperature = 0.7f,
                            .top_p = 0.9f,
                            .seed = 7};
  return value;
}

static QMaxModelReceipt receipt_for(const char *directory, QMaxModelFile *files,
                                    char graph[QMAX_MODEL_MAX_PATH_BYTES],
                                    char tokens[QMAX_MODEL_MAX_PATH_BYTES],
                                    char vector[QMAX_MODEL_MAX_PATH_BYTES]) {
  join(graph, QMAX_MODEL_MAX_PATH_BYTES, directory, "graph.mef");
  join(tokens, QMAX_MODEL_MAX_PATH_BYTES, directory, "tokenizer.bin");
  join(vector, QMAX_MODEL_MAX_PATH_BYTES, directory, "vector.bin");
  files[0] = (QMaxModelFile){.path = graph, .bytes = sizeof(kMef) - 1};
  files[1] = (QMaxModelFile){.path = tokens, .bytes = sizeof(kTokenizer) - 1};
  files[2] = (QMaxModelFile){.path = vector, .bytes = sizeof(kVector) - 1};
  memcpy(files[0].sha256, kMefSha, 64);
  memcpy(files[1].sha256, kTokenizerSha, 64);
  memcpy(files[2].sha256, kVectorSha, 64);
  QMaxModelReceipt receipt = {.runner_name = "fake-bonsai-runner",
                              .runner_abi = QMAX_MODEL_RUNNER_ABI,
                              .backend = "cpu",
                              .context_tokens = 64,
                              .max_output_tokens = 16,
                              .files = files,
                              .file_count = 3};
  return receipt;
}

int main(int argc, char **argv) {
  assert(argc == 2);
  const char *directory = argv[1];
  char graph[QMAX_MODEL_MAX_PATH_BYTES], tokens[QMAX_MODEL_MAX_PATH_BYTES];
  char vector[QMAX_MODEL_MAX_PATH_BYTES], link[QMAX_MODEL_MAX_PATH_BYTES];
  char bulk[QMAX_MODEL_MAX_PATH_BYTES];
  join(graph, sizeof(graph), directory, "graph.mef");
  join(tokens, sizeof(tokens), directory, "tokenizer.bin");
  join(vector, sizeof(vector), directory, "vector.bin");
  join(bulk, sizeof(bulk), directory, "bulk.bin");
  write_file(graph, kMef, sizeof(kMef) - 1);
  write_file(tokens, kTokenizer, sizeof(kTokenizer) - 1);
  write_file(vector, kVector, sizeof(kVector) - 1);
  char *bulk_data = malloc(40000);
  assert(bulk_data);
  memset(bulk_data, 'a', 40000);
  write_file(bulk, bulk_data, 40000);
  free(bulk_data);

  QMaxModelFile files[QMAX_MODEL_MAX_FILES];
  QMaxModelReceipt receipt =
      receipt_for(directory, files, graph, tokens, vector);
  files[3] = (QMaxModelFile){.path = bulk, .bytes = 40000};
  memcpy(files[3].sha256, kBulkSha, 64);
  receipt.file_count = 4;
  QMaxError error;

  /* Schema and integrity. */
  QMaxModelReceipt bad = receipt;
  bad.file_count = 0;
  assert(qmax_model_verify(&bad, &error) == QMAX_CONTRACT_MISMATCH);
  expect_no_path(&error);
  assert(qmax_model_verify(&receipt, &error) == QMAX_OK && error.message[0] == '\0');

  bad = receipt;
  bad.files = files;
  files[0].bytes -= 1;
  assert(qmax_model_verify(&bad, &error) == QMAX_CONTRACT_MISMATCH);
  files[0].bytes += 1;

  FILE *mutate = fopen(graph, "r+b");
  assert(mutate && fputc('X', mutate) != EOF && fclose(mutate) == 0);
  assert(qmax_model_verify(&receipt, &error) == QMAX_CONTRACT_MISMATCH);
  expect_no_path(&error);
  write_file(graph, kMef, sizeof(kMef) - 1);
  assert(qmax_model_verify(&receipt, &error) == QMAX_OK);

  join(link, sizeof(link), directory, "link.mef");
  unlink(link);
  assert(symlink(graph, link) == 0);
  QMaxModelFile linked[4];
  memcpy(linked, files, sizeof(linked));
  linked[0].path = link;
  bad = receipt;
  bad.files = linked;
  assert(qmax_model_verify(&bad, &error) == QMAX_CONTRACT_MISMATCH);
  unlink(link);

  /* Runner contract, opt-outs and capability. */
  const QMaxModelRunner *runner = fake_model_runner();
  QMaxModelRunner wrong = *runner;
  wrong.abi = "quenderin-max-model-runner-0";
  QMaxModelCapability capability;
  assert(qmax_model_capability(&wrong, &receipt, 1, &capability) == QMAX_CONTRACT_MISMATCH);
  assert(capability.contract_ok == 0 && capability.available == 0);
  assert(strlen(capability.reason) > 0);

  unsetenv("MODULAR_TELEMETRY_ENABLED");
  unsetenv("MODULAR_CRASH_REPORTING_ENABLED");
  assert(qmax_model_capability(runner, &receipt, 1, &capability) == QMAX_OK);
  assert(capability.contract_ok == 1 && capability.available == 0);
  assert(strstr(capability.reason, "opt-outs") != NULL);
  assert(setenv("MODULAR_TELEMETRY_ENABLED", "0", 1) == 0);
  assert(setenv("MODULAR_CRASH_REPORTING_ENABLED", "0", 1) == 0);

  assert(qmax_model_capability(runner, &receipt, 0, &capability) == QMAX_OK);
  assert(capability.contract_ok == 1 && capability.load_probe_passed == 0 &&
         capability.available == 0);
  assert(!strcmp(capability.backend, "cpu"));
  assert(qmax_model_capability(runner, &receipt, 1, &capability) == QMAX_OK);
  assert(capability.available == 1);

  bad = receipt;
  bad.runner_abi = "quenderin-max-model-runner-0";
  QMaxModel *model = NULL;
  assert(qmax_model_open(runner, &bad, &model, &error) == QMAX_CONTRACT_MISMATCH &&
         model == NULL);

  unsetenv("MODULAR_TELEMETRY_ENABLED");
  unsetenv("MODULAR_CRASH_REPORTING_ENABLED");
  assert(qmax_model_open(runner, &receipt, &model, &error) == QMAX_UNAVAILABLE &&
         model == NULL);
  expect_no_path(&error);
  assert(setenv("MODULAR_TELEMETRY_ENABLED", "0", 1) == 0);
  assert(setenv("MODULAR_CRASH_REPORTING_ENABLED", "0", 1) == 0);

  fake_model_reset(0, 0, 1, 0, -1);
  assert(qmax_model_open(runner, &receipt, &model, &error) == QMAX_UNAVAILABLE &&
         model == NULL && fake_model_live() == 0);
  fake_model_reset(0, 0, 2, 0, -1);
  assert(qmax_model_open(runner, &receipt, &model, &error) == QMAX_UNAVAILABLE &&
         model == NULL && fake_model_live() == 0);
  assert(error.code == QMAX_UNAVAILABLE);
  assert(strlen(error.message) > 0);
  expect_no_path(&error);

  fake_model_reset(0, 0, 0, 0, -1);
  assert(qmax_model_open(runner, &receipt, &model, &error) == QMAX_OK && model);
  assert(fake_model_live() == 1);

  QMaxModelRequest ask = request("hi", 16);
  QMaxModelPerformance performance;
  Sink sink;
  memset(&sink, 0, sizeof(sink));

  /* Normal streaming, including a UTF-8 character split across two pieces. */
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_OK);
  expect_text(&sink, "hello \xc3\xa9!");
  assert(performance.status == 0 && performance.decoded_tokens == 6 &&
         performance.prompt_tokens == 2);
  assert(performance.prefill_ms >= 0.0 && performance.decode_ms >= 0.0 &&
         performance.first_token_ms >= 0.0 && performance.max_gap_ms >= 0.0);
  assert(isfinite(performance.prefill_ms) && isfinite(performance.decode_ms));

  /* Three- and four-byte characters, invalid sequences and a truncated tail. */
  fake_model_reset(0, 0, 0, 0, -1);
  fake_model_script(kThreeFourByte,
                    sizeof(kThreeFourByte) / sizeof(kThreeFourByte[0]));
  memset(&sink, 0, sizeof(sink));
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_OK);
  expect_text(&sink, "\xe2\x82\xac\xf0\x9f\x98\x80!");

  fake_model_reset(0, 0, 0, 0, -1);
  fake_model_script(kOverlong, sizeof(kOverlong) / sizeof(kOverlong[0]));
  memset(&sink, 0, sizeof(sink));
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_OK);
  expect_text(&sink, "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd!");

  fake_model_reset(0, 0, 0, 0, -1);
  fake_model_script(kSurrogate, sizeof(kSurrogate) / sizeof(kSurrogate[0]));
  memset(&sink, 0, sizeof(sink));
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_OK);
  expect_text(&sink, "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd!");

  fake_model_reset(0, 0, 0, 0, -1);
  fake_model_script(kTruncated, sizeof(kTruncated) / sizeof(kTruncated[0]));
  memset(&sink, 0, sizeof(sink));
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_OK);
  expect_text(&sink, "\xef\xbf\xbd");
  assert(performance.status == 0);

  /* Single-flight: a nested generate from the sink returns busy. */
  fake_model_reset(0, 0, 0, 0, -1);
  memset(&sink, 0, sizeof(sink));
  sink.busy_model = model;
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_OK);
  assert(sink.busy_code == QMAX_BUSY);

  /* Close during generation is refused instead of freeing live state. */
  fake_model_reset(0, 0, 0, 0, -1);
  memset(&sink, 0, sizeof(sink));
  sink.close_model = model;
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_OK);
  assert(sink.close_code == QMAX_BUSY);

  /* Cancellation observed at the next token boundary. */
  fake_model_reset(0, 0, 0, 0, -1);
  memset(&sink, 0, sizeof(sink));
  sink.cancel_after = 1;
  sink.cancel_model = model;
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_CANCELLED);
  expect_text(&sink, "he");
  assert(performance.status == 1 && performance.decoded_tokens == 1);

  /* Stop before the first token. */
  fake_model_reset(0, 0, 0, 0, -1);
  memset(&sink, 0, sizeof(sink));
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, stop_immediately,
                             NULL, &performance, &error) == QMAX_CANCELLED);
  assert(sink.length == 0 && performance.status == 1 &&
         performance.decoded_tokens == 0 && performance.prompt_tokens == 2);

  /* Streaming sink abort. */
  fake_model_reset(0, 0, 0, 0, -1);
  memset(&sink, 0, sizeof(sink));
  sink.abort_after = 2;
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_CANCELLED);
  expect_text(&sink, "hello");
  assert(performance.status == 4);

  /* Runner failure preserves partial text and is not training evidence. */
  fake_model_reset(3, 0, 0, 0, -1);
  memset(&sink, 0, sizeof(sink));
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_RUNTIME_ERROR);
  expect_text(&sink, "hello");
  assert(performance.status == 2);
  assert(!strcmp(error.message, "injected runner failure"));

  /* Oversized piece is a contract mismatch. */
  fake_model_reset(0, 1, 0, 0, -1);
  memset(&sink, 0, sizeof(sink));
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_CONTRACT_MISMATCH);
  assert(performance.status == 2 && sink.length == 0);
  expect_no_path(&error);

  /* Output cap without EOG. */
  fake_model_reset(0, 0, 0, 0, -1);
  ask = request("hi", 2);
  memset(&sink, 0, sizeof(sink));
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_OK);
  assert(performance.status == 3 && performance.decoded_tokens == 2);
  expect_text(&sink, "hello");

  /* Prompt consumes nearly all of the context: output budget is clamped. */
  char long_prompt[64];
  memset(long_prompt, 'a', sizeof(long_prompt));
  long_prompt[63] = '\0';
  fake_model_reset(0, 0, 0, 0, 0);
  ask = request(long_prompt, 16);
  memset(&sink, 0, sizeof(sink));
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_OK);
  assert(performance.status == 5 && performance.prompt_tokens == 63 &&
         performance.decoded_tokens == 1);

  /* Invalid requests are rejected before generation and say so. */
  ask = request("hi", 17);
  memset(&performance, 0, sizeof(performance));
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_INVALID_ARGUMENT);
  assert(performance.status == 6 && performance.decoded_tokens == 0);
  ask = request("hi", 4);
  ask.top_p = 0.0f;
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_INVALID_ARGUMENT);
  assert(performance.status == 6);
  char *huge = malloc(QMAX_MODEL_MAX_PROMPT_BYTES + 1);
  assert(huge);
  memset(huge, 'a', QMAX_MODEL_MAX_PROMPT_BYTES + 1);
  ask = request("x", 4);
  ask.prompt = huge;
  ask.prompt_bytes = QMAX_MODEL_MAX_PROMPT_BYTES + 1;
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_INVALID_ARGUMENT);
  assert(performance.status == 6);
  free(huge);

  /* Zero prompt tokens is rejected, not treated as an empty answer. */
  fake_model_reset(0, 0, 0, 1, -1);
  ask = request("hi", 4);
  memset(&sink, 0, sizeof(sink));
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_CONTRACT_MISMATCH);
  assert(performance.status == 2);

  /* The stream budget is reachable and stops a flooding runner. */
  QMaxModelReceipt big = receipt;
  big.context_tokens = QMAX_MODEL_MAX_CONTEXT;
  big.max_output_tokens = QMAX_MODEL_MAX_OUTPUT;
  QMaxModel *flood_model = NULL;
  fake_model_reset(0, 0, 0, 0, -1);
  fake_model_flood(1);
  assert(qmax_model_open(runner, &big, &flood_model, &error) == QMAX_OK && flood_model);
  ask = request("hi", QMAX_MODEL_MAX_OUTPUT);
  memset(&sink, 0, sizeof(sink));
  sink.discard = 1;
  assert(qmax_model_generate(flood_model, &ask, sink_emit, &sink, NULL, NULL,
                             &performance, &error) == QMAX_CONTRACT_MISMATCH);
  assert(performance.status == 2 && sink.length == QMAX_MODEL_MAX_STREAM_BYTES);
  expect_no_path(&error);
  assert(qmax_model_close(flood_model) == QMAX_OK);
  fake_model_flood(0);

  /* Contended single-flight: another thread holds the lease. */
  fake_model_reset(0, 0, 0, 0, -1);
  fake_model_block(1);
  ThreadRun run;
  memset(&run, 0, sizeof(run));
  run.model = model;
  run.request = request("hi", 16);
  pthread_t thread;
  assert(pthread_create(&thread, NULL, thread_generate, &run) == 0);
  fake_model_wait_entered();
  QMaxError busy_error;
  Sink probe_sink;
  memset(&probe_sink, 0, sizeof(probe_sink));
  assert(qmax_model_generate(model, &run.request, sink_emit, &probe_sink, NULL,
                             NULL, NULL, &busy_error) == QMAX_BUSY);
  assert(qmax_model_close(model) == QMAX_BUSY);
  fake_model_release();
  assert(pthread_join(thread, NULL) == 0);
  assert(run.result == QMAX_OK);
  expect_text(&run.sink, "hello \xc3\xa9!");

  /* NULL diagnostics and performance pointers are tolerated. */
  fake_model_reset(0, 0, 0, 0, -1);
  memset(&sink, 0, sizeof(sink));
  ask = request("hi", 16);
  assert(qmax_model_generate(model, &ask, sink_emit, &sink, NULL, NULL, NULL,
                             NULL) == QMAX_OK);
  expect_text(&sink, "hello \xc3\xa9!");

  assert(qmax_model_close(model) == QMAX_OK);
  assert(fake_model_closed());
  QMaxModel *null_error_model = NULL;
  fake_model_reset(0, 0, 0, 0, -1);
  assert(qmax_model_open(runner, &receipt, &null_error_model, NULL) == QMAX_OK &&
         null_error_model);
  assert(qmax_model_close(null_error_model) == QMAX_OK);
  assert(fake_model_closed());
  assert(qmax_model_close(NULL) == QMAX_OK);
  qmax_model_cancel(NULL);
  puts("MAX model adapter double: verification, lifecycle, UTF-8, cancellation, budgets, single-flight and cleanup passed; no MAX runtime or model used");
  return 0;
}
