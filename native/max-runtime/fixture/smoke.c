#include "quenderin_max.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int stop(void *context) { (void)context; return 1; }

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  int64_t shape[] = {4};
  float weight[] = {2, 3, 4, 5}, input[] = {1, 2, 3, 4};
  float output[] = {-1, -1, -1, -1}, expected[] = {2, 6, 12, 20};
  QMaxGraphSpec graph = {
    .mef_path = argv[1], .input = {"input0", shape, 1},
    .output = {"output0", shape, 1}, .weight_name = "weight",
    .weight_data = weight, .weight_elements = 4
  };
  QMaxSession *session = NULL;
  QMaxError error = {0};
  if (qmax_open(&graph, &session, &error) != QMAX_OK || !session) {
    fprintf(stderr, "MAX open failed: %s\n", error.message); return 1;
  }
  /* The bridge owns a copy; caller changes cannot alter registry weights. */
  memset(weight, 0, sizeof(weight));
  if (qmax_execute(session, input, 3, output, 4, NULL, NULL, &error) != QMAX_INVALID_ARGUMENT || output[0] != -1) goto failed;
  if (qmax_execute(session, input, 4, input, 4, NULL, NULL, &error) != QMAX_INVALID_ARGUMENT) goto failed;
  if (qmax_execute(session, input, 4, output, 4, stop, NULL, &error) != QMAX_CANCELLED || output[0] != -1) goto failed;
  for (int iteration = 0; iteration < 3; ++iteration) {
    if (qmax_execute(session, input, 4, output, 4, NULL, NULL, &error) != QMAX_OK || memcmp(output, expected, sizeof(output))) goto failed;
  }
  qmax_close(session);
  session = NULL;
  graph.mef_path = "/nonexistent/quenderin-max.mef";
  if (qmax_open(&graph, &session, &error) != QMAX_INVALID_ARGUMENT || session) return 1;
  qmax_close(NULL);
  /* No prompt/model/user data is emitted. The expected answer alone is public. */
  printf("{\"schema\":1,\"backend\":\"max-c-api\",\"device\":\"cpu\",\"graph\":\"weighted-multiply-f32-4\",\"output\":[2,6,12,20],\"executions\":3,\"wrongShapeRejected\":true,\"stopBeforeStepRejected\":true,\"llmInference\":false}\n");
  return 0;
failed:
  fprintf(stderr, "MAX CPU fixture failed: %s\n", error.message);
  qmax_close(session);
  return 1;
}
