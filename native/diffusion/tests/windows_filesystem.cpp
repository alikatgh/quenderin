/* Windows hosted filesystem tests. Only this process's newly created fixture
 * directory is written/removed. The diffusion runtime is the synthetic stub. */
#include "quenderin_diffusion.h"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <array>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>
namespace fs=std::filesystem;
void require(bool value,const char*message){if(!value)throw std::runtime_error(message);}
std::string read(const fs::path&path){std::ifstream file(path,std::ios::binary);return {std::istreambuf_iterator<char>(file),{}};}
void write(const fs::path&path,const char*value){std::ofstream file(path,std::ios::binary);file<<value;require(static_cast<bool>(file),"Unable to write private fixture");}
struct Fixture {
    fs::path root;
    Fixture(){root=fs::temp_directory_path()/(L"quenderin-windows-fixture-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));require(fs::create_directory(root),"Private fixture path already exists");
        write(root/L"model.safetensors","fixture-model-data");write(root/L"vae.safetensors","fixture-vae-data");write(root/L"encoder.gguf","GGUFfixture-data");}
    ~Fixture(){std::error_code ec;fs::remove_all(root,ec);}
    quenderin_diffusion_status generate(const fs::path&output,quenderin_diffusion_progress callback=nullptr,void*user=nullptr){
        std::array<std::string,4>paths={(root/L"model.safetensors").u8string(),(root/L"encoder.gguf").u8string(),(root/L"vae.safetensors").u8string(),output.u8string()};
        quenderin_diffusion_request request{};request.abi_version=1;request.struct_size=sizeof(request);request.model=QUENDERIN_DIFFUSION_FLUX3_KLEIN;
        request.diffusion_path=paths[0].c_str();request.text_encoder_path=paths[1].c_str();request.vae_path=paths[2].c_str();request.output_path=paths[3].c_str();request.prompt="fixture:success";
        request.width=64;request.height=64;request.steps=16;request.threads=2;request.seed=42;
        auto*engine=quenderin_diffusion_create();require(engine!=nullptr,"Fixture engine creation failed");char error[512]{};
        auto status=quenderin_diffusion_generate(engine,&request,callback,user,error,sizeof(error));quenderin_diffusion_destroy(engine);
        if(status!=QUENDERIN_DIFFUSION_OK)std::fprintf(stderr,"Expected/reported native status %d: %s\n",status,error);return status;
    }
};
bool symlink(const fs::path&link,const fs::path&target,bool directory){
    DWORD flags=directory?SYMBOLIC_LINK_FLAG_DIRECTORY:0;
    if(CreateSymbolicLinkW(link.c_str(),target.c_str(),flags|0x2))return true;
    return CreateSymbolicLinkW(link.c_str(),target.c_str(),flags)!=0;
}
struct OutputRace {fs::path output;bool attempted=false;};
void race(uint32_t step,uint32_t total,void*data){if(step==total){auto*r=static_cast<OutputRace*>(data);write(r->output,"original-racing-file");r->attempted=true;}}
struct RenameAttempt {fs::path from,to;bool attempted=false,renamed=false;};
void rename_parent(uint32_t,uint32_t,void*data){auto*r=static_cast<RenameAttempt*>(data);r->attempted=true;if(MoveFileExW(r->from.c_str(),r->to.c_str(),0))r->renamed=true;}
int main(int argc,char**argv){
    try{
        Fixture f;
        if(argc>1&&std::string(argv[1])=="reparse"){
            auto target=f.root/L"target";require(fs::create_directory(target),"Unable to create reparse fixture target");write(target/L"original.txt","user-original");
            auto link=f.root/L"directory-link";
            if(!symlink(link,target,true)){std::fprintf(stderr,"BLOCKED: Windows symlink creation privilege unavailable (%lu)\n",GetLastError());return 77;}
            require(f.generate(link/L"image.png")==QUENDERIN_DIFFUSION_INVALID,"Reparse output parent accepted");require(!fs::exists(target/L"image.png"),"Reparse target was written");
            auto output=f.root/L"output-link.png";require(symlink(output,target/L"original.txt",false),"Unable to create output link fixture");
            require(f.generate(output)==QUENDERIN_DIFFUSION_INVALID,"Existing reparse output accepted");require(read(target/L"original.txt")=="user-original","Original changed through output link");
        }else{
            auto unicode=f.root/fs::u8path(u8"生成-é-😀.png");require(f.generate(unicode)==QUENDERIN_DIFFUSION_OK,"Unicode exclusive PNG generation failed");
            auto bytes=read(unicode);require(bytes.size()>8&&bytes.substr(0,8)==std::string("\x89PNG\r\n\x1a\n",8),"Output is not a PNG");
            auto original=f.root/L"existing.png";write(original,"user-original");require(f.generate(original)==QUENDERIN_DIFFUSION_INVALID,"Existing output accepted");require(read(original)=="user-original","Existing output overwritten");
            OutputRace output_race{f.root/L"racing.png"};require(f.generate(output_race.output,race,&output_race)==QUENDERIN_DIFFUSION_OUTPUT_FAILED,"Racing original accepted");require(output_race.attempted&&read(output_race.output)=="original-racing-file","Racing original changed");
            for(auto filename:{L"NUL.png",L"image.png:stream",L"alias.png.",L"COM1.png"})require(f.generate(f.root/filename)==QUENDERIN_DIFFUSION_INVALID,"Windows alias accepted");
            RenameAttempt attempt{f.root,f.root.wstring()+L"-moved"};auto result=f.generate(f.root/L"parent-lock.png",rename_parent,&attempt);
            if(attempt.renamed)require(MoveFileExW(attempt.to.c_str(),attempt.from.c_str(),0)!=0,"Unable to restore moved private fixture");
            require(result==QUENDERIN_DIFFUSION_OK,"Pinned-parent generation failed");require(attempt.attempted&&!attempt.renamed&&fs::exists(f.root),"Model/output parent was not pinned");
        }
        std::puts("Windows synthetic filesystem fixture passed; no real inference tested.");return 0;
    }catch(const std::exception&e){std::fprintf(stderr,"Windows fixture failed: %s\n",e.what());return 1;}
}
