#include "quenderin_diffusion.h"
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif
namespace {
volatile std::sig_atomic_t interrupted=0;
void signal_handler(int){interrupted=1;}
std::string json(const std::string&s){std::string out="\"";for(unsigned char c:s){if(c=='"'||c=='\\'){out+='\\';out+=c;}else if(c<32){char value[7];std::snprintf(value,sizeof(value),"\\u%04x",c);out+=value;}else out+=c;}return out+'"';}
uint32_t number(const std::string&value){size_t n=0;auto parsed=std::stoul(value,&n);if(n!=value.size()||parsed>0xffffffffUL)throw std::runtime_error("Invalid numeric option.");return static_cast<uint32_t>(parsed);}
void progress(uint32_t step,uint32_t steps,void*){std::fprintf(stderr,"{\"step\":%u,\"steps\":%u}\n",step,steps);}
}
int run(int argc,char**argv){
    try{
        if(argc==2 && std::string(argv[1])=="--version"){std::printf("{\"abiVersion\":%u,\"revision\":%s}\n",quenderin_diffusion_abi(),json(quenderin_diffusion_revision()).c_str());return 0;}
        const std::map<std::string,bool>allowed={{"--model",true},{"--diffusion",true},{"--text-encoder",true},{"--vae",true},{"--tokenizer",true},{"--prompt",true},{"--negative-prompt",true},{"--output",true},{"--width",true},{"--height",true},{"--steps",true},{"--threads",true},{"--seed",true}};
        std::map<std::string,std::string>args;
        for(int i=1;i<argc;i+=2){std::string key=argv[i];if(!allowed.count(key)||i+1>=argc||args.count(key))throw std::runtime_error("Unknown, duplicate or missing CLI option.");args[key]=argv[i+1];}
        for(auto key:{"--model","--diffusion","--text-encoder","--vae","--prompt","--output"})if(!args.count(key))throw std::runtime_error("Missing required CLI option.");
        quenderin_diffusion_request request{};request.abi_version=1;request.struct_size=sizeof(request);
        if(args["--model"]=="flux3-image-klein")request.model=QUENDERIN_DIFFUSION_FLUX3_KLEIN;
        else if(args["--model"]=="moss-image-base")request.model=QUENDERIN_DIFFUSION_MOSS_BASE;
        else if(args["--model"]=="moss-image-sft")request.model=QUENDERIN_DIFFUSION_MOSS_SFT;
        else throw std::runtime_error("Unknown image model.");
        request.diffusion_path=args["--diffusion"].c_str();request.text_encoder_path=args["--text-encoder"].c_str();request.vae_path=args["--vae"].c_str();request.tokenizer_path=args.count("--tokenizer")?args["--tokenizer"].c_str():nullptr;
        request.prompt=args["--prompt"].c_str();request.negative_prompt=args["--negative-prompt"].c_str();request.output_path=args["--output"].c_str();
        request.width=args.count("--width")?number(args["--width"]):512;request.height=args.count("--height")?number(args["--height"]):512;
        request.steps=args.count("--steps")?number(args["--steps"]):(request.model==QUENDERIN_DIFFUSION_FLUX3_KLEIN?16:50);request.threads=args.count("--threads")?number(args["--threads"]):4;
        size_t consumed=0;request.seed=args.count("--seed")?std::stoll(args["--seed"],&consumed):0;if(args.count("--seed")&&consumed!=args["--seed"].size())throw std::runtime_error("Invalid seed.");
        auto*engine=quenderin_diffusion_create();if(!engine)throw std::runtime_error("Unable to create image engine.");
        std::signal(SIGINT,signal_handler);std::signal(SIGTERM,signal_handler);std::atomic<bool>done{false};
        std::thread monitor([&]{while(!done.load()){if(interrupted)quenderin_diffusion_cancel(engine);std::this_thread::sleep_for(std::chrono::milliseconds(50));}});
        char error[512]{};auto status=quenderin_diffusion_generate(engine,&request,progress,nullptr,error,sizeof(error));done=true;monitor.join();quenderin_diffusion_destroy(engine);
        if(status!=QUENDERIN_DIFFUSION_OK){std::printf("{\"ok\":false,\"status\":%d,\"error\":%s}\n",status,json(error).c_str());return static_cast<int>(status);}
        std::printf("{\"ok\":true,\"path\":%s,\"width\":%u,\"height\":%u}\n",json(request.output_path).c_str(),request.width,request.height);return 0;
    }catch(const std::exception&e){std::printf("{\"ok\":false,\"status\":1,\"error\":%s}\n",json(e.what()).c_str());return 1;}
}
#if defined(_WIN32)
// Windows process arguments are UTF-16. Keep the library's C ABI and the JSON
// protocol UTF-8, including non-ASCII output paths and prompts.
int wmain(int argc,wchar_t**wide_argv){
    try{
        std::vector<std::string>values;values.reserve(argc);
        for(int i=0;i<argc;++i){
            int length=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,wide_argv[i],-1,nullptr,0,nullptr,nullptr);
            if(length<=0)throw std::runtime_error("Invalid Unicode command-line argument.");
            std::string value(static_cast<size_t>(length),'\0');
            if(!WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,wide_argv[i],-1,value.data(),length,nullptr,nullptr))throw std::runtime_error("Unable to read Unicode command-line argument.");
            value.resize(static_cast<size_t>(length)-1);values.push_back(std::move(value));
        }
        std::vector<char*>argv;argv.reserve(values.size());for(auto &value:values)argv.push_back(value.data());
        return run(argc,argv.data());
    }catch(const std::exception&e){std::printf("{\"ok\":false,\"status\":1,\"error\":%s}\n",json(e.what()).c_str());return 1;}
}
#else
int main(int argc,char**argv){return run(argc,argv);}
#endif
