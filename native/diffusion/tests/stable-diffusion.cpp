#include "stable-diffusion.h"
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <thread>
struct sd_ctx_t {std::atomic<bool>cancelled{false};bool moss=false;};
static void(*progress)(int,int,float,void*)=nullptr;static void*progress_user=nullptr;
void sd_ctx_params_init(sd_ctx_params_t*p){*p={};}
sd_ctx_t*new_sd_ctx(const sd_ctx_params_t*p){if(std::strstr(p->diffusion_model_path,"load-fail"))return nullptr;auto*c=new sd_ctx_t;c->moss=p->tokenizer&&*p->tokenizer;return c;}
void free_sd_ctx(sd_ctx_t*c){delete c;}
void sd_img_gen_params_init(sd_img_gen_params_t*p){*p={};}
void sd_set_progress_callback(void(*cb)(int,int,float,void*),void*user){progress=cb;progress_user=user;}
void sd_set_log_callback(void(*)(sd_log_level_t,const char*,void*),void*){}
void sd_cancel_generation(sd_ctx_t*c,sd_cancel_mode_t){c->cancelled=true;}
bool generate_image(sd_ctx_t*c,const sd_img_gen_params_t*p,sd_image_t**out,int*count){
    *out=nullptr;*count=0;
    if(std::strcmp(p->prompt,"fixture:fail")==0)return false;
    if(p->batch_count!=1||p->sample_params.guidance.txt_cfg!=(c->moss?3.f:1.f)||std::abs(p->sample_params.flow_shift-(c->moss?5.f:6.93f))>.001f)return false;
    for(int step=1;step<=20;++step){if(c->cancelled)return false;if(progress)progress(step,20,0.f,progress_user);std::this_thread::sleep_for(std::chrono::milliseconds(2));}
    if(c->cancelled)return false;
    *out=new sd_image_t[1];*count=1;auto&image=(*out)[0];image.width=p->width;image.height=p->height;image.channel=3;image.data=new uint8_t[image.width*image.height*3];std::memset(image.data,123,image.width*image.height*3);return true;
}
void free_sd_images(sd_image_t*images,int count){for(int i=0;i<count;++i)delete[]images[i].data;delete[]images;}
