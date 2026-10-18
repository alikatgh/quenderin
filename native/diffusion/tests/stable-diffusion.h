/* Synthetic ABI fixture, not an inference implementation or model. */
#ifndef DIFFUSION_TEST_STUB_H
#define DIFFUSION_TEST_STUB_H
#include <stdint.h>
enum sd_log_level_t { SD_LOG_INFO };
enum sd_cancel_mode_t { SD_CANCEL_ALL, SD_CANCEL_NEW_LATENTS, SD_CANCEL_RESET };
enum sample_method_t { EULER_SAMPLE_METHOD };
enum scheduler_t { DISCRETE_SCHEDULER };
struct sd_ctx_t;
struct sd_ctx_params_t {
    const char *diffusion_model_path,*llm_path,*vae_path,*tokenizer;
    int n_threads;bool enable_mmap,disable_prefetch,auto_fit;int conditioning_cache_size;
};
struct sd_image_t { uint32_t width,height,channel;uint8_t*data; };
struct sd_guidance_params_t {float txt_cfg;};
struct sd_sample_params_t {int sample_steps;sample_method_t sample_method;scheduler_t scheduler;sd_guidance_params_t guidance;float flow_shift;};
struct sd_img_gen_params_t {const char *prompt,*negative_prompt;int width,height;int64_t seed;int batch_count;sd_sample_params_t sample_params;sd_image_t*ref_images;int ref_images_count;};
void sd_ctx_params_init(sd_ctx_params_t*);
sd_ctx_t*new_sd_ctx(const sd_ctx_params_t*);
void free_sd_ctx(sd_ctx_t*);
void sd_img_gen_params_init(sd_img_gen_params_t*);
bool generate_image(sd_ctx_t*,const sd_img_gen_params_t*,sd_image_t**,int*);
void free_sd_images(sd_image_t*,int);
void sd_cancel_generation(sd_ctx_t*,sd_cancel_mode_t);
void sd_set_progress_callback(void(*)(int,int,float,void*),void*);
void sd_set_log_callback(void(*)(sd_log_level_t,const char*,void*),void*);
#endif
