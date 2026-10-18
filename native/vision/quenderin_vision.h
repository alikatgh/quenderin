#ifndef QUENDERIN_VISION_H
#define QUENDERIN_VISION_H
#include <stddef.h>
#include <stdint.h>
#ifdef _WIN32
# ifdef QUENDERIN_VISION_BUILD_DLL
#  define QV_API __declspec(dllexport)
# else
#  define QV_API __declspec(dllimport)
# endif
#else
# define QV_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
/* ABI 1. One handle owns one model, projector and context. Call load/generate/free
 * serially on its owner worker; cancel may run concurrently while the handle is
 * alive. Cancellation is sticky: create a new handle after cancelling. The owner must join its worker before free. No caller llama/ggml objects
 * cross this ABI; this target links the same pinned llama and mtmd, once. */
typedef struct quenderin_vision quenderin_vision;
typedef int (*quenderin_vision_output)(const char * utf8, size_t bytes, void * user);
typedef struct {
    uint32_t abi;                 /* must be 1 */
    const char * model_id;         /* exact shared/vision-models.json ID */
    const char * model_path;       /* absolute, regular pinned GGUF */
    const char * projector_path;   /* absolute, regular pinned mmproj GGUF */
    uint32_t context_size;         /* 1024..8192; default client value 4096 */
    uint32_t threads;              /* 1..16 */
} quenderin_vision_load_options;
typedef struct {
    uint32_t abi;                 /* must be 1 */
    const char * image_path;       /* one JPEG or PNG still <=8MiB */
    const char * prompt;           /* UTF-8, 1..32768 bytes, no media markers */
    uint32_t max_tokens;           /* 1..1024 */
} quenderin_vision_request;
QV_API uint32_t quenderin_vision_runtime_abi(void);
QV_API const char * quenderin_vision_runtime_revision(void);
QV_API const char * quenderin_vision_patch_sha256(void);
QV_API quenderin_vision * quenderin_vision_create(void);
/* All nonzero results fail closed. output is final visible answer only, with
 * model reasoning/control delimiters removed; callback returning 0 cancels. */
QV_API int quenderin_vision_load(quenderin_vision *, const quenderin_vision_load_options *);
QV_API int quenderin_vision_generate(quenderin_vision *, const quenderin_vision_request *,
                                   quenderin_vision_output, void * user);
QV_API void quenderin_vision_cancel(quenderin_vision *);
QV_API const char * quenderin_vision_last_error(const quenderin_vision *);
QV_API uint32_t quenderin_vision_generated_tokens(const quenderin_vision *);
QV_API void quenderin_vision_free(quenderin_vision *);
#ifdef __cplusplus
}
#endif
#endif
