#ifndef QUENDERIN_SPEECH_H
#define QUENDERIN_SPEECH_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#if defined(QUENDERIN_SPEECH_BUILD_DLL)
#define QS_API __declspec(dllexport)
#else
#define QS_API __declspec(dllimport)
#endif
#else
#define QS_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Only this ABI crosses the isolated native speech boundary. Never expose
 * ggml or transcribe.h symbols directly from the dynamic library. */
#define QUENDERIN_SPEECH_ABI 1u

typedef struct quenderin_speech_engine quenderin_speech_engine;

typedef enum {
    QUENDERIN_SPEECH_OK = 0,
    QUENDERIN_SPEECH_INVALID = 1,
    QUENDERIN_SPEECH_BUSY = 2,
    QUENDERIN_SPEECH_CANCELLED = 3,
    QUENDERIN_SPEECH_LOAD_FAILED = 4,
    QUENDERIN_SPEECH_TRANSCRIBE_FAILED = 5,
    QUENDERIN_SPEECH_UNSUPPORTED = 6,
    QUENDERIN_SPEECH_INTERNAL = 7
} quenderin_speech_status;

typedef struct {
    uint32_t abi_version;
    size_t struct_size;
    const char *model_path;       /* mandatory canonical local GGUF/.bin path */
    const char *vad_path;         /* optional canonical Silero VAD GGUF path */
    const char *wav_path;         /* canonical 16 kHz mono PCM WAV path, or NULL if pcm_f32 provided */
    const float *pcm_f32;         /* optional 16 kHz mono float32 samples in [-1, 1] */
    size_t pcm_samples;
    uint32_t sample_rate;         /* must be 16000 */
    const char *language;         /* BCP-47 short code or "auto"/NULL */
    const char *prompt;           /* optional context prompt */
    const char * const *vocabulary; /* optional custom spelling terms */
    uint32_t vocabulary_count;    /* 0..100 */
    uint32_t threads;             /* 1..8 */
    bool translate;
    bool timestamps;
} quenderin_speech_request;

typedef struct {
    char *text;
    char *language;
    char *backend;
    char *segments_json;
    int64_t duration_ms;
    bool truncated;
    bool aborted;
} quenderin_speech_result;

QS_API uint32_t quenderin_speech_abi(void);
QS_API const char *quenderin_speech_revision(void);
QS_API quenderin_speech_engine *quenderin_speech_create(void);
QS_API quenderin_speech_status quenderin_speech_destroy(quenderin_speech_engine *engine);
QS_API quenderin_speech_status quenderin_speech_cancel(quenderin_speech_engine *engine);
QS_API quenderin_speech_status quenderin_speech_validate(
    const quenderin_speech_request *request, char *error, size_t error_size);
QS_API quenderin_speech_status quenderin_speech_transcribe(
    quenderin_speech_engine *engine, const quenderin_speech_request *request,
    quenderin_speech_result *result, char *error, size_t error_size);
QS_API void quenderin_speech_result_free(quenderin_speech_result *result);

#ifdef __cplusplus
}
#endif

#endif
