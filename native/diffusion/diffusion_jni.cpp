#include "quenderin_diffusion.h"
#include <jni.h>
#include <atomic>
#include <cstdint>
#include <stdexcept>
#include <string>

namespace {
quenderin_diffusion_engine *engine(jlong handle) { return reinterpret_cast<quenderin_diffusion_engine*>(static_cast<uintptr_t>(handle)); }
std::string utf8(JNIEnv *env,jstring input,bool required) {
    if(!input){if(required)throw std::runtime_error("Missing image generation text or path.");return {};}
    const jchar *chars=env->GetStringChars(input,nullptr);
    if(!chars)throw std::runtime_error("Unable to read image generation text.");
    jsize count=env->GetStringLength(input);std::string value;bool invalid=false;
    for(jsize i=0;i<count;++i){
        uint32_t point=chars[i];
        if(point>=0xd800 && point<=0xdbff){if(i+1>=count || chars[i+1]<0xdc00 || chars[i+1]>0xdfff){invalid=true;break;}point=0x10000+((point-0xd800)<<10)+(chars[++i]-0xdc00);}
        else if(point>=0xdc00 && point<=0xdfff){invalid=true;break;}
        if(!point){invalid=true;break;}
        if(point<0x80)value.push_back(static_cast<char>(point));
        else if(point<0x800){value.push_back(static_cast<char>(0xc0|(point>>6)));value.push_back(static_cast<char>(0x80|(point&63)));}
        else if(point<0x10000){value.push_back(static_cast<char>(0xe0|(point>>12)));value.push_back(static_cast<char>(0x80|((point>>6)&63)));value.push_back(static_cast<char>(0x80|(point&63)));}
        else {value.push_back(static_cast<char>(0xf0|(point>>18)));value.push_back(static_cast<char>(0x80|((point>>12)&63)));value.push_back(static_cast<char>(0x80|((point>>6)&63)));value.push_back(static_cast<char>(0x80|(point&63)));}
        if(value.size()>8192){invalid=true;break;}
    }
    env->ReleaseStringChars(input,chars);
    if(invalid)throw std::runtime_error("Image generation text is invalid or too long.");
    return value;
}
struct Progress {
    JavaVM *vm=nullptr;jobject object=nullptr;jmethodID method=nullptr;
    quenderin_diffusion_engine *engine=nullptr;std::atomic<bool>failed{false};
};
void on_progress(uint32_t step,uint32_t total,void*data){
    auto*p=static_cast<Progress*>(data);if(!p || !p->object || p->failed.load())return;
    JNIEnv*env=nullptr;bool attached=false;
    jint state=p->vm->GetEnv(reinterpret_cast<void**>(&env),JNI_VERSION_1_6);
    if(state==JNI_EDETACHED){if(p->vm->AttachCurrentThread(&env,nullptr)!=JNI_OK){p->failed=true;quenderin_diffusion_cancel(p->engine);return;}attached=true;}
    else if(state!=JNI_OK){p->failed=true;quenderin_diffusion_cancel(p->engine);return;}
    env->CallVoidMethod(p->object,p->method,static_cast<jint>(step),static_cast<jint>(total));
    if(env->ExceptionCheck()){env->ExceptionClear();p->failed=true;quenderin_diffusion_cancel(p->engine);}
    if(attached)p->vm->DetachCurrentThread();
}
}
extern "C" JNIEXPORT jint JNICALL Java_ai_quenderin_core_NativeImageGenerationBridge_abi(JNIEnv*,jclass){return quenderin_diffusion_abi();}
extern "C" JNIEXPORT jlong JNICALL Java_ai_quenderin_core_NativeImageGenerationBridge_create(JNIEnv*,jclass){return static_cast<jlong>(reinterpret_cast<uintptr_t>(quenderin_diffusion_create()));}
extern "C" JNIEXPORT jint JNICALL Java_ai_quenderin_core_NativeImageGenerationBridge_cancel(JNIEnv*,jclass,jlong handle){return quenderin_diffusion_cancel(engine(handle));}
extern "C" JNIEXPORT jint JNICALL Java_ai_quenderin_core_NativeImageGenerationBridge_destroy(JNIEnv*,jclass,jlong handle){return quenderin_diffusion_destroy(engine(handle));}
extern "C" JNIEXPORT jstring JNICALL Java_ai_quenderin_core_NativeImageGenerationBridge_generate(
    JNIEnv*env,jclass,jlong handle,jint kind,jstring diffusion,jstring encoder,jstring vae,jstring tokenizer,
    jstring prompt,jstring negative,jstring output,jint width,jint height,jint steps,jint threads,jlong seed,jobject progress){
    jobject callback=nullptr;
    try{
        auto d=utf8(env,diffusion,true),te=utf8(env,encoder,true),v=utf8(env,vae,true),t=utf8(env,tokenizer,false),p=utf8(env,prompt,true),n=utf8(env,negative,false),o=utf8(env,output,true);
        Progress info;info.engine=engine(handle);
        if(progress){
            if(env->GetJavaVM(&info.vm)!=JNI_OK)throw std::runtime_error("Unable to access native progress callback.");
            callback=env->NewGlobalRef(progress);if(!callback)throw std::runtime_error("Unable to retain native progress callback.");
            info.object=callback;jclass cls=env->GetObjectClass(progress);if(!cls)throw std::runtime_error("Unable to inspect native progress callback.");
            info.method=env->GetMethodID(cls,"onProgress","(II)V");env->DeleteLocalRef(cls);
            if(!info.method)throw std::runtime_error("Native progress callback signature is invalid.");
        }
        quenderin_diffusion_request request{};request.abi_version=QUENDERIN_DIFFUSION_ABI;request.struct_size=sizeof(request);request.model=static_cast<quenderin_diffusion_model>(kind);
        request.diffusion_path=d.c_str();request.text_encoder_path=te.c_str();request.vae_path=v.c_str();request.tokenizer_path=t.empty()?nullptr:t.c_str();
        request.prompt=p.c_str();request.negative_prompt=n.c_str();request.output_path=o.c_str();request.width=width;request.height=height;request.steps=steps;request.threads=threads;request.seed=seed;
        char error[512]{};auto status=quenderin_diffusion_generate(info.engine,&request,progress?on_progress:nullptr,&info,error,sizeof(error));
        if(callback){env->DeleteGlobalRef(callback);callback=nullptr;}
        if(info.failed)return env->NewStringUTF("Image progress callback failed.");
        return status==QUENDERIN_DIFFUSION_OK?nullptr:env->NewStringUTF(*error?error:"Local image generation failed.");
    }catch(const std::exception&error){if(callback)env->DeleteGlobalRef(callback);if(env->ExceptionCheck())return nullptr;return env->NewStringUTF(error.what());}
    catch(...){if(callback)env->DeleteGlobalRef(callback);if(env->ExceptionCheck())return nullptr;return env->NewStringUTF("Native image generation failed.");}
}
