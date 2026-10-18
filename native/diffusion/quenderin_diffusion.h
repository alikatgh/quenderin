#ifndef QUENDERIN_DIFFUSION_H
#define QUENDERIN_DIFFUSION_H
#include <stddef.h>
#include <stdint.h>
#if defined(_WIN32)
#if defined(QUENDERIN_DIFFUSION_BUILD_DLL)
#define QD_API __declspec(dllexport)
#else
#define QD_API __declspec(dllimport)
#endif
#else
#define QD_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif

/* Only this ABI crosses the isolated diffusion library boundary. Never include
 * ggml or stable-diffusion.h in Swift/JNI/application translation units. */
#define QUENDERIN_DIFFUSION_ABI 1u
typedef struct quenderin_diffusion_engine quenderin_diffusion_engine;
typedef enum {
    QUENDERIN_DIFFUSION_OK = 0,
    QUENDERIN_DIFFUSION_INVALID = 1,
    QUENDERIN_DIFFUSION_BUSY = 2,
    QUENDERIN_DIFFUSION_CANCELLED = 3,
    QUENDERIN_DIFFUSION_LOAD_FAILED = 4,
    QUENDERIN_DIFFUSION_GENERATION_FAILED = 5,
    QUENDERIN_DIFFUSION_OUTPUT_FAILED = 6,
    QUENDERIN_DIFFUSION_INTERNAL = 7
} quenderin_diffusion_status;
typedef enum {
    QUENDERIN_DIFFUSION_FLUX3_KLEIN = 1,
    QUENDERIN_DIFFUSION_MOSS_BASE = 2,
    QUENDERIN_DIFFUSION_MOSS_SFT = 3
} quenderin_diffusion_model;
typedef struct {
    uint32_t width, height, channels;
    const uint8_t *pixels; /* packed RGB/RGBA; retained by caller until return */
    size_t byte_count; /* exactly width * height * channels */
} quenderin_diffusion_image;
typedef struct {
    uint32_t abi_version;
    size_t struct_size;
    quenderin_diffusion_model model;
    const char *diffusion_path;
    const char *text_encoder_path;
    const char *vae_path;
    const char *tokenizer_path; /* mandatory for MOSS; NULL/empty for FLUX */
    const char *prompt;
    const char *negative_prompt;
    const char *output_path; /* new absolute local .png path; never overwritten */
    uint32_t width, height; /* 64..1024, multiples of 16 */
    uint32_t steps;         /* 1..50 */
    uint32_t threads;       /* 1..8 */
    int64_t seed;           /* nonnegative, reproducibility is backend-dependent */
    const quenderin_diffusion_image *reference_images; /* FLUX only, at most 10 */
    size_t reference_count;
} quenderin_diffusion_request;
typedef void (*quenderin_diffusion_progress)(uint32_t step, uint32_t steps, void *user);

QD_API uint32_t quenderin_diffusion_abi(void);
QD_API const char *quenderin_diffusion_revision(void);
QD_API quenderin_diffusion_engine *quenderin_diffusion_create(void);
/* Caller must retain the handle until generate returns. Destroy returns BUSY
 * during a run; callers must serialize destroy against starting a new run. */
QD_API quenderin_diffusion_status quenderin_diffusion_destroy(quenderin_diffusion_engine *engine);
QD_API quenderin_diffusion_status quenderin_diffusion_validate(
    const quenderin_diffusion_request *request, char *error, size_t error_size);
/* Synchronous. Run on a native worker/actor, never a UI thread. All engines in
 * this process share one try-lock because upstream callbacks are global. */
QD_API quenderin_diffusion_status quenderin_diffusion_generate(
    quenderin_diffusion_engine *engine, const quenderin_diffusion_request *request,
    quenderin_diffusion_progress progress, void *user, char *error, size_t error_size);
/* Thread-safe during generate. Cancellation during model loading is remembered
 * and stops before sampling when the synchronous upstream loader returns.
 * Cancellation is sticky for this handle; create a fresh handle for another job. */
QD_API quenderin_diffusion_status quenderin_diffusion_cancel(quenderin_diffusion_engine *engine);
#ifdef __cplusplus
}
#endif
#endif
