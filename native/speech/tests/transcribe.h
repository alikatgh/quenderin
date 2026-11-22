/* Synthetic ABI fixture for host compilation; mirrors anomalyco/transcribe.cpp include/transcribe.h. */
#ifndef TRANSCRIBE_H
#define TRANSCRIBE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    TRANSCRIBE_OK = 0,
    TRANSCRIBE_ERR_INVALID_ARG = 1,
    TRANSCRIBE_ERR_NOT_IMPLEMENTED = 2,
    TRANSCRIBE_ERR_FILE_NOT_FOUND = 3,
    TRANSCRIBE_ERR_GGUF = 4,
    TRANSCRIBE_ERR_UNSUPPORTED_ARCH = 5,
    TRANSCRIBE_ERR_UNSUPPORTED_VARIANT = 6,
    TRANSCRIBE_ERR_OOM = 7,
    TRANSCRIBE_ERR_BACKEND = 8,
    TRANSCRIBE_ERR_SAMPLE_RATE = 9,
    TRANSCRIBE_ERR_UNSUPPORTED_LANGUAGE = 10,
    TRANSCRIBE_ERR_UNSUPPORTED_TASK = 11,
    TRANSCRIBE_ERR_UNSUPPORTED_TIMESTAMPS = 12,
    TRANSCRIBE_ERR_ABORTED = 13,
    TRANSCRIBE_ERR_BAD_STRUCT_SIZE = 14,
    TRANSCRIBE_ERR_UNSUPPORTED_PNC = 15,
    TRANSCRIBE_ERR_UNSUPPORTED_ITN = 16,
    TRANSCRIBE_ERR_INPUT_TOO_LONG = 17,
    TRANSCRIBE_ERR_OUTPUT_TRUNCATED = 18,
    TRANSCRIBE_ERR_OUTPUT_REPETITION = 19,
    TRANSCRIBE_ERR_UNSUPPORTED_ROLE = 20,
    TRANSCRIBE_ERR_INPUT_TOO_SHORT = 21
} transcribe_status;

typedef enum {
    TRANSCRIBE_TASK_TRANSCRIBE = 0,
    TRANSCRIBE_TASK_TRANSLATE = 1,
    TRANSCRIBE_TASK_INSTRUCT = 2
} transcribe_task;

typedef enum {
    TRANSCRIBE_TIMESTAMPS_NONE = 0,
    TRANSCRIBE_TIMESTAMPS_AUTO = 1,
    TRANSCRIBE_TIMESTAMPS_SEGMENT = 2,
    TRANSCRIBE_TIMESTAMPS_WORD = 3,
    TRANSCRIBE_TIMESTAMPS_TOKEN = 4
} transcribe_timestamp_kind;

typedef enum { TRANSCRIBE_KV_TYPE_AUTO = 0 } transcribe_kv_type;
enum transcribe_pnc_mode { TRANSCRIBE_PNC_MODE_DEFAULT = 0 };
enum transcribe_itn_mode { TRANSCRIBE_ITN_MODE_DEFAULT = 0 };
enum transcribe_diarize_mode { TRANSCRIBE_DIARIZE_MODE_DEFAULT = 0 };

typedef enum { TRANSCRIBE_BACKEND_AUTO = 0, TRANSCRIBE_BACKEND_CPU = 1 } transcribe_backend_request;

typedef enum {
    TRANSCRIBE_FEATURE_VOCABULARY = 7,
    TRANSCRIBE_FEATURE_CONTEXT_PROMPT = 8
} transcribe_feature;

struct transcribe_ext { uint64_t size; uint32_t kind; };
struct transcribe_device;
typedef struct transcribe_device *transcribe_device_t;
struct transcribe_model;
struct transcribe_session;

struct transcribe_model_load_params {
    uint64_t struct_size;
    transcribe_backend_request backend;
    transcribe_device_t device;
    bool no_mmap;
};

struct transcribe_session_params {
    uint64_t struct_size;
    int n_threads;
    transcribe_kv_type kv_type;
    int32_t n_ctx;
};

struct transcribe_run_params {
    uint64_t struct_size;
    transcribe_task task;
    transcribe_timestamp_kind timestamps;
    enum transcribe_pnc_mode pnc;
    enum transcribe_itn_mode itn;
    enum transcribe_diarize_mode diarize;
    const char *language;
    const char *target_language;
    bool keep_special_tags;
    const struct transcribe_ext *family;
    int32_t spec_k_drafts;
    const char * const *vocabulary;
    int32_t n_vocabulary;
    const char *prompt;
    const char *prefix;
};

struct transcribe_segment {
    uint64_t struct_size;
    int64_t t0_ms;
    int64_t t1_ms;
    int first_word;
    int n_words;
    int first_token;
    int n_tokens;
    const char *text;
    int32_t speaker_id;
};

typedef bool (*transcribe_abort_callback)(void *user_data);

void transcribe_model_load_params_init(struct transcribe_model_load_params *params);
void transcribe_session_params_init(struct transcribe_session_params *params);
void transcribe_run_params_init(struct transcribe_run_params *params);
void transcribe_segment_init(struct transcribe_segment *out);
const char *transcribe_status_string(int status);
transcribe_status transcribe_model_load_file(const char *path, const struct transcribe_model_load_params *params, struct transcribe_model **out_model);
void transcribe_model_free(struct transcribe_model *model);
const char *transcribe_model_backend(const struct transcribe_model *model);
bool transcribe_model_supports(const struct transcribe_model *model, transcribe_feature feature);
transcribe_status transcribe_session_init(struct transcribe_model *model, const struct transcribe_session_params *params, struct transcribe_session **out_session);
void transcribe_session_free(struct transcribe_session *session);
void transcribe_set_abort_callback(struct transcribe_session *session, transcribe_abort_callback cb, void *user_data);
transcribe_status transcribe_run(struct transcribe_session *session, const float *pcm, int n_samples, const struct transcribe_run_params *params);
bool transcribe_was_aborted(const struct transcribe_session *session);
bool transcribe_was_truncated(const struct transcribe_session *session);
const char *transcribe_full_text(const struct transcribe_session *session);
const char *transcribe_detected_language(const struct transcribe_session *session);
int transcribe_n_segments(const struct transcribe_session *session);
transcribe_status transcribe_get_segment(const struct transcribe_session *session, int i, struct transcribe_segment *out);

#ifdef __cplusplus
}
#endif
#endif
