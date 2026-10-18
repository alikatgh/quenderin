#include "quenderin_diffusion.h"
#include "stable-diffusion.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#if defined(_WIN32)
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#ifndef QUENDERIN_DIFFUSION_REVISION
#error Build must identify the exact diffusion runtime revision
#endif
struct quenderin_diffusion_engine {
    std::mutex state;
    bool running = false;
    std::atomic<bool> cancelled{false};
    sd_ctx_t *context = nullptr;
};
namespace {
std::mutex process_generation;
using Status = quenderin_diffusion_status;
struct Error { Status status; std::string message; };
void fail(Status status, const char *message) { throw Error{status, message}; }
void copy_error(char *output, size_t capacity, const char *message) {
    if (output && capacity) std::snprintf(output, capacity, "%s", message);
}
size_t text_length(const char *text, size_t maximum, bool required) {
    if (!text) { if (required) fail(QUENDERIN_DIFFUSION_INVALID, "Missing required text or path."); return 0; }
    size_t size = 0;
    while (size <= maximum && text[size]) ++size;
    if (size > maximum || (required && !size)) fail(QUENDERIN_DIFFUSION_INVALID, "Text or path length is invalid.");
    return size;
}
std::filesystem::path local_path(const char *value) {
    size_t size = text_length(value, 4096, true);
    for (size_t i=0; i<size; ++i) if (static_cast<unsigned char>(value[i]) < 32) fail(QUENDERIN_DIFFUSION_INVALID, "Path contains a control character.");
    auto path = std::filesystem::u8path(value);
    if (!path.is_absolute() || path.lexically_normal() != path || std::strstr(value, "://")) fail(QUENDERIN_DIFFUSION_INVALID, "An absolute normalized local path is required.");
#if defined(_WIN32)
    // Exclude UNC/network/device namespaces, drive-relative names, ADS, and DOS
    // aliases before any filesystem operation. The public C ABI always uses UTF-8.
    auto root = path.root_name().native();
    if (root.size()!=2 || root[1]!=L':' || !((root[0]>=L'A'&&root[0]<=L'Z')||(root[0]>=L'a'&&root[0]<=L'z')))
        fail(QUENDERIN_DIFFUSION_INVALID,"A local Windows drive path is required.");
    UINT drive=GetDriveTypeW(path.root_path().c_str());
    if(drive!=DRIVE_FIXED && drive!=DRIVE_REMOVABLE && drive!=DRIVE_RAMDISK)
        fail(QUENDERIN_DIFFUSION_INVALID,"Network and device paths are not supported.");
    for(const auto &part:path.relative_path()) {
        auto name=part.native();
        if(name.empty() || name.back()==L'.' || name.back()==L' ' || name.find_first_of(L":*?\"<>|")!=std::wstring::npos)
            fail(QUENDERIN_DIFFUSION_INVALID,"Windows path contains an alias or invalid component.");
        auto base=name.substr(0,name.find(L'.'));
        for(auto &c:base)if(c>=L'a'&&c<=L'z')c-=L'a'-L'A';
        bool numbered=base.size()==4 && (base.substr(0,3)==L"COM" || base.substr(0,3)==L"LPT")
            && ((base[3]>=L'1'&&base[3]<=L'9')||base[3]==L'\u00b9'||base[3]==L'\u00b2'||base[3]==L'\u00b3');
        if(base==L"CON"||base==L"PRN"||base==L"AUX"||base==L"NUL"||numbered)
            fail(QUENDERIN_DIFFUSION_INVALID,"Windows device aliases are not supported.");
    }
    path.make_preferred();
#endif
    return path;
}
#if defined(_WIN32)
class WindowsHandle {
    HANDLE value=INVALID_HANDLE_VALUE;
public:
    explicit WindowsHandle(HANDLE handle):value(handle){}
    WindowsHandle(const WindowsHandle&)=delete;
    WindowsHandle&operator=(const WindowsHandle&)=delete;
    WindowsHandle(WindowsHandle&&other)noexcept:value(other.value){other.value=INVALID_HANDLE_VALUE;}
    WindowsHandle&operator=(WindowsHandle&&other)noexcept{if(this!=&other){close();value=other.value;other.value=INVALID_HANDLE_VALUE;}return *this;}
    ~WindowsHandle(){close();}
    HANDLE get()const{return value;}
    bool close(){if(value==INVALID_HANDLE_VALUE)return true;auto old=value;value=INVALID_HANDLE_VALUE;return CloseHandle(old)!=0;}
};
bool same_windows_path(std::wstring actual,std::wstring expected) {
    if(actual.compare(0,4,L"\\\\?\\")==0)actual.erase(0,4);
    for(auto &c:actual)if(c==L'/')c=L'\\';
    for(auto &c:expected)if(c==L'/')c=L'\\';
    while(actual.size()>3&&actual.back()==L'\\')actual.pop_back();
    while(expected.size()>3&&expected.back()==L'\\')expected.pop_back();
    return actual.size()==expected.size() && CompareStringOrdinal(actual.data(),static_cast<int>(actual.size()),expected.data(),static_cast<int>(expected.size()),TRUE)==CSTR_EQUAL;
}
void verify_windows_handle(HANDLE handle,const std::filesystem::path &path,bool directory,Status failure) {
    BY_HANDLE_FILE_INFORMATION info{};
    if(GetFileType(handle)!=FILE_TYPE_DISK || !GetFileInformationByHandle(handle,&info)
        || (info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)
        || static_cast<bool>(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)!=directory)
        fail(failure,"Local paths must not contain reparse points or special files.");
    DWORD size=GetFinalPathNameByHandleW(handle,nullptr,0,FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
    if(!size || size>32768)fail(failure,"Unable to verify the local Windows path.");
    std::vector<wchar_t> actual(static_cast<size_t>(size)+1);
    DWORD written=GetFinalPathNameByHandleW(handle,actual.data(),static_cast<DWORD>(actual.size()),FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
    if(!written || written>=actual.size() || !same_windows_path(std::wstring(actual.data(),written),path.native()))
        fail(failure,"Windows path resolves through an alias or reparse point.");
}
std::vector<WindowsHandle> lock_windows_chain(const std::filesystem::path &path,bool file,Status failure=QUENDERIN_DIFFUSION_INVALID) {
    std::vector<WindowsHandle> handles;
    auto current=path.root_path();
    auto open_component=[&](const std::filesystem::path &part,bool directory){
        // Deny rename/delete and data writes while held. Attribute-only opens
        // have separate Windows sharing semantics, so final-path/reparse checks
        // on the actual output handle are still required before writing pixels.
        DWORD access=directory?(FILE_LIST_DIRECTORY|FILE_READ_ATTRIBUTES):GENERIC_READ;
        HANDLE raw=CreateFileW(part.c_str(),access,FILE_SHARE_READ,nullptr,OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
        if(raw==INVALID_HANDLE_VALUE)fail(failure,"Unable to lock a regular local Windows path.");
        WindowsHandle handle(raw);verify_windows_handle(raw,part,directory,failure);handles.push_back(std::move(handle));
    };
    open_component(current,true);
    for(const auto &part:path.relative_path()) {
        current/=part;open_component(current,!(file&&current==path));
    }
    return handles;
}
#endif
void component(const char *name, const char *extension, const char *magic = nullptr) {
    auto path = local_path(name);
    std::error_code ec;
#if defined(_WIN32)
    auto locked=lock_windows_chain(path,true);
#else
    auto status = std::filesystem::symlink_status(path, ec);
    if (ec || !std::filesystem::is_regular_file(status) || std::filesystem::canonical(path, ec) != path || ec)
        fail(QUENDERIN_DIFFUSION_INVALID, "Model component must be an existing regular local file without symlinks.");
#endif
    if (path.extension() != extension || std::filesystem::file_size(path, ec) < 8 || ec)
        fail(QUENDERIN_DIFFUSION_INVALID, "Model component format or size is invalid.");
    if (magic) {
        char bytes[4]{}; std::ifstream input(path, std::ios::binary); input.read(bytes, sizeof(bytes));
        if (!input || std::memcmp(bytes, magic, sizeof(bytes))) fail(QUENDERIN_DIFFUSION_INVALID, "Text encoder must contain GGUF data.");
    }
}
void validate(const quenderin_diffusion_request *r) {
    if (!r || r->abi_version != QUENDERIN_DIFFUSION_ABI || r->struct_size != sizeof(*r)) fail(QUENDERIN_DIFFUSION_INVALID, "Image runtime ABI mismatch.");
    if (r->model < QUENDERIN_DIFFUSION_FLUX3_KLEIN || r->model > QUENDERIN_DIFFUSION_MOSS_SFT) fail(QUENDERIN_DIFFUSION_INVALID, "Unknown image model.");
    if (r->width<64 || r->height<64 || r->width>1024 || r->height>1024 || r->width%16 || r->height%16 || !r->steps || r->steps>50 || !r->threads || r->threads>8 || r->seed<0)
        fail(QUENDERIN_DIFFUSION_INVALID, "Image dimensions, steps, threads or seed exceed the local generation bounds.");
    text_length(r->prompt, 8192, true); text_length(r->negative_prompt, 8192, false);
    component(r->diffusion_path, ".safetensors"); component(r->text_encoder_path, ".gguf", "GGUF"); component(r->vae_path, ".safetensors");
    if (r->model == QUENDERIN_DIFFUSION_FLUX3_KLEIN) {
        if (text_length(r->tokenizer_path, 4096, false)) fail(QUENDERIN_DIFFUSION_INVALID, "FLUX does not accept an external tokenizer component.");
    } else {
        component(r->tokenizer_path, ".json");
        if (r->reference_count) fail(QUENDERIN_DIFFUSION_INVALID, "MOSS supports text-to-image requests only.");
    }
    if (r->reference_count>10 || (r->reference_count && !r->reference_images) || (!r->reference_count && r->reference_images))
        fail(QUENDERIN_DIFFUSION_INVALID, "Reference image set is invalid.");
    for (size_t i=0;i<r->reference_count;++i) {
        const auto &image=r->reference_images[i];
        if (!image.pixels || !image.width || !image.height || image.width>1024 || image.height>1024 || (image.channels!=3 && image.channels!=4)
                || image.byte_count != static_cast<size_t>(image.width)*image.height*image.channels)
            fail(QUENDERIN_DIFFUSION_INVALID, "Reference image dimensions or pixels are invalid.");
    }
    auto output=local_path(r->output_path);
    std::error_code ec;
    if (output.extension()!=".png" || std::filesystem::exists(std::filesystem::symlink_status(output,ec))) fail(QUENDERIN_DIFFUSION_INVALID, "Output must be a new PNG path.");
    ec.clear();
#if defined(_WIN32)
    auto output_parent=lock_windows_chain(output.parent_path(),false);
#else
    if (std::filesystem::canonical(output.parent_path(),ec)!=output.parent_path() || ec || !std::filesystem::is_directory(output.parent_path()))
        fail(QUENDERIN_DIFFUSION_INVALID, "Output parent must be an existing local directory without symlinks.");
#endif
    for (const char *source : {r->diffusion_path,r->text_encoder_path,r->vae_path,r->tokenizer_path})
        if (source && *source && output == std::filesystem::u8path(source)) fail(QUENDERIN_DIFFUSION_INVALID, "Output cannot replace a model component.");
}
uint32_t crc32(const uint8_t *bytes,size_t length) {
    uint32_t c=0xffffffffu;
    for(size_t i=0;i<length;++i) { c^=bytes[i]; for(int bit=0;bit<8;++bit)c=(c>>1)^((0u-(c&1u))&0xedb88320u); }
    return c^0xffffffffu;
}
void be32(std::vector<uint8_t>& out,uint32_t n) { for(int shift=24;shift>=0;shift-=8)out.push_back(static_cast<uint8_t>(n>>shift)); }
void chunk(std::vector<uint8_t>& out,const char *kind,const std::vector<uint8_t>& data) {
    be32(out,static_cast<uint32_t>(data.size())); size_t start=out.size();
    out.insert(out.end(),kind,kind+4); out.insert(out.end(),data.begin(),data.end()); be32(out,crc32(out.data()+start,data.size()+4));
}
std::vector<uint8_t> png(const sd_image_t &image) {
    if (!image.data || image.width<1 || image.height<1 || image.width>1024 || image.height>1024 || (image.channel!=3 && image.channel!=4))
        fail(QUENDERIN_DIFFUSION_GENERATION_FAILED,"Runtime returned invalid pixels.");
    size_t stride=static_cast<size_t>(image.width)*image.channel;
    std::vector<uint8_t> raw; raw.reserve((stride+1)*image.height);
    for(uint32_t y=0;y<image.height;++y) { raw.push_back(0);raw.insert(raw.end(),image.data+y*stride,image.data+(y+1)*stride); }
    std::vector<uint8_t> deflate{0x78,0x01}; uint32_t a=1,b=0;
    for(uint8_t v:raw) {a=(a+v)%65521;b=(b+a)%65521;}
    for(size_t offset=0;offset<raw.size();) {
        uint16_t size=static_cast<uint16_t>(std::min<size_t>(65535,raw.size()-offset));
        deflate.push_back(offset+size==raw.size()?1:0);
        deflate.push_back(size&255);deflate.push_back(size>>8);uint16_t inverse=~size;
        deflate.push_back(inverse&255);deflate.push_back(inverse>>8);
        deflate.insert(deflate.end(),raw.begin()+offset,raw.begin()+offset+size);offset+=size;
    }
    be32(deflate,(b<<16)|a);
    std::vector<uint8_t> out{137,80,78,71,13,10,26,10},header;
    be32(header,image.width);be32(header,image.height);header.insert(header.end(),{8,static_cast<uint8_t>(image.channel==4?6:2),0,0,0});
    chunk(out,"IHDR",header);chunk(out,"IDAT",deflate);chunk(out,"IEND",{});return out;
}
void save_new(const char *path,const std::vector<uint8_t>& data) {
#if defined(_WIN32)
    auto output=local_path(path);
    auto parents=lock_windows_chain(output.parent_path(),false,QUENDERIN_DIFFUSION_OUTPUT_FAILED);
    HANDLE raw=CreateFileW(output.c_str(),GENERIC_WRITE|DELETE|FILE_READ_ATTRIBUTES,0,nullptr,CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
    if(raw==INVALID_HANDLE_VALUE)fail(QUENDERIN_DIFFUSION_OUTPUT_FAILED,"Unable to create a new output file; existing files are preserved.");
    WindowsHandle file(raw);
    BY_HANDLE_FILE_INFORMATION created{};
    bool identified=GetFileInformationByHandle(raw,&created)!=0;
    auto remove_failed_file=[&]{
        // Delete only this still-open newly created file by handle, never by a
        // path that could now name a different file. Keep it if identity fails.
        BY_HANDLE_FILE_INFORMATION current{};
        if(identified && GetFileInformationByHandle(raw,&current)
            && current.dwVolumeSerialNumber==created.dwVolumeSerialNumber
            && current.nFileIndexHigh==created.nFileIndexHigh && current.nFileIndexLow==created.nFileIndexLow) {
            FILE_DISPOSITION_INFO disposition{};disposition.DeleteFile=TRUE;
            SetFileInformationByHandle(raw,FileDispositionInfo,&disposition,sizeof(disposition));
        }
    };
    try{verify_windows_handle(raw,output,false,QUENDERIN_DIFFUSION_OUTPUT_FAILED);}
    catch(...){remove_failed_file();throw;}
    bool good=identified;
    for(size_t offset=0;good&&offset<data.size();) {
        DWORD wanted=static_cast<DWORD>(std::min<size_t>(1024*1024,data.size()-offset)),written=0;
        if(!WriteFile(raw,data.data()+offset,wanted,&written,nullptr)||!written||written>wanted){good=false;break;}
        offset+=written;
    }
    if(good&&!FlushFileBuffers(raw))good=false;
    if(!good)remove_failed_file();
    if(!file.close())good=false;
    if(!good)fail(QUENDERIN_DIFFUSION_OUTPUT_FAILED,"Unable to finish the new PNG output.");
#else
    int fd=open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0) fail(QUENDERIN_DIFFUSION_OUTPUT_FAILED,"Unable to create a new output file; existing files are preserved.");
    struct stat created{}; bool identified=fstat(fd,&created)==0; bool good=true;
    for(size_t offset=0;offset<data.size();) {
        ssize_t n=write(fd,data.data()+offset,data.size()-offset);
        if(n<0 && errno==EINTR)continue;
        if(n<=0){good=false;break;}offset+=static_cast<size_t>(n);
    }
    if(good && fsync(fd)!=0)good=false;
    if(close(fd)!=0)good=false;
    if(!good) {
        struct stat current{};
        if(identified && lstat(path,&current)==0 && current.st_dev==created.st_dev && current.st_ino==created.st_ino)unlink(path);
        fail(QUENDERIN_DIFFUSION_OUTPUT_FAILED,"Unable to finish the new PNG output.");
    }
#endif
}
struct Progress { quenderin_diffusion_progress callback;void*user; };
void progress_callback(int step,int total,float,void *data) {
    auto *progress=static_cast<Progress*>(data);
    if(progress && progress->callback && step>=0 && total>0)progress->callback(static_cast<uint32_t>(step),static_cast<uint32_t>(total),progress->user);
}
void quiet_log(sd_log_level_t,const char*,void*) {}
struct Images {sd_image_t*data=nullptr;int count=0;~Images(){if(data)free_sd_images(data,count);}};
struct Running {
    quenderin_diffusion_engine*engine;
#if defined(_WIN32)
    std::vector<WindowsHandle> component_handles;
#endif
    std::atomic<bool> finished{false};
    std::thread cancel_monitor;
    void monitor_cancel() {
        cancel_monitor = std::thread([this] {
            while (!finished.load()) {
                if (engine->cancelled.load()) {
                    std::lock_guard<std::mutex> lock(engine->state);
                    if (engine->context) sd_cancel_generation(engine->context, SD_CANCEL_ALL);
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
        });
    }
    ~Running(){
        finished.store(true);
        if (cancel_monitor.joinable()) cancel_monitor.join();
        sd_set_progress_callback(nullptr,nullptr);sd_set_log_callback(nullptr,nullptr);
        sd_ctx_t*context;
        {std::lock_guard<std::mutex>lock(engine->state);context=engine->context;engine->context=nullptr;}
        if(context)free_sd_ctx(context);
        std::lock_guard<std::mutex>lock(engine->state);engine->running=false;
    }
};
}
extern "C" {
uint32_t quenderin_diffusion_abi(void){return QUENDERIN_DIFFUSION_ABI;}
const char*quenderin_diffusion_revision(void){return QUENDERIN_DIFFUSION_REVISION;}
quenderin_diffusion_engine*quenderin_diffusion_create(void){try{return new quenderin_diffusion_engine;}catch(...){return nullptr;}}
Status quenderin_diffusion_destroy(quenderin_diffusion_engine*engine){
    if(!engine)return QUENDERIN_DIFFUSION_INVALID;
    {std::lock_guard<std::mutex>lock(engine->state);if(engine->running)return QUENDERIN_DIFFUSION_BUSY;}
    delete engine;return QUENDERIN_DIFFUSION_OK;
}
Status quenderin_diffusion_validate(const quenderin_diffusion_request*r,char*error,size_t size){
    copy_error(error,size,"");try{validate(r);return QUENDERIN_DIFFUSION_OK;}catch(const Error&e){copy_error(error,size,e.message.c_str());return e.status;}catch(...){copy_error(error,size,"Unable to validate image request.");return QUENDERIN_DIFFUSION_INTERNAL;}
}
Status quenderin_diffusion_cancel(quenderin_diffusion_engine*engine){
    if(!engine)return QUENDERIN_DIFFUSION_INVALID;
    std::lock_guard<std::mutex>lock(engine->state);engine->cancelled.store(true);
    if(engine->context)sd_cancel_generation(engine->context,SD_CANCEL_ALL);
    return QUENDERIN_DIFFUSION_OK;
}
Status quenderin_diffusion_generate(quenderin_diffusion_engine*engine,const quenderin_diffusion_request*r,quenderin_diffusion_progress callback,void*user,char*error,size_t size){
    copy_error(error,size,"");
    if(!engine){copy_error(error,size,"Missing image engine.");return QUENDERIN_DIFFUSION_INVALID;}
    std::unique_lock<std::mutex>global(process_generation,std::try_to_lock);
    if(!global.owns_lock()){copy_error(error,size,"An image generation is already running.");return QUENDERIN_DIFFUSION_BUSY;}
    {std::lock_guard<std::mutex>lock(engine->state);if(engine->running)return QUENDERIN_DIFFUSION_BUSY;engine->running=true;}
    Running running{engine};
    try{
        if(engine->cancelled.load())fail(QUENDERIN_DIFFUSION_CANCELLED,"Image generation was cancelled.");
        validate(r);Progress progress{callback,user};sd_set_progress_callback(progress_callback,&progress);sd_set_log_callback(quiet_log,nullptr);
#if defined(_WIN32)
        // Keep model paths and their ancestors immutable for the entire loader,
        // sampling and context teardown. The upstream API accepts paths, not FDs.
        for(const char *component_path:{r->diffusion_path,r->text_encoder_path,r->vae_path,r->tokenizer_path})if(component_path&&*component_path){
            auto handles=lock_windows_chain(local_path(component_path),true);
            for(auto &handle:handles)running.component_handles.push_back(std::move(handle));
        }
#endif
        sd_ctx_params_t context_params;sd_ctx_params_init(&context_params);
        context_params.diffusion_model_path=r->diffusion_path;context_params.llm_path=r->text_encoder_path;context_params.vae_path=r->vae_path;
        context_params.tokenizer=r->tokenizer_path;context_params.n_threads=static_cast<int>(r->threads);
        context_params.enable_mmap=true;context_params.disable_prefetch=true;context_params.auto_fit=true;context_params.conditioning_cache_size=0;
        sd_ctx_t*context=new_sd_ctx(&context_params);
        if(!context)fail(QUENDERIN_DIFFUSION_LOAD_FAILED,"Local image components could not be loaded by the pinned runtime.");
        {std::lock_guard<std::mutex>lock(engine->state);engine->context=context;}
        // Upstream resets its own cancel flag at operation entry. Keep our request's
        // cancellation sticky and reassert it until the operation has returned.
        running.monitor_cancel();
        if(engine->cancelled.load())fail(QUENDERIN_DIFFUSION_CANCELLED,"Image generation was cancelled.");
        sd_img_gen_params_t params;sd_img_gen_params_init(&params);
        params.prompt=r->prompt;params.negative_prompt=r->negative_prompt?r->negative_prompt:"";params.width=r->width;params.height=r->height;
        params.seed=r->seed;params.batch_count=1;params.sample_params.sample_steps=r->steps;params.sample_params.sample_method=EULER_SAMPLE_METHOD;
        params.sample_params.scheduler=DISCRETE_SCHEDULER;params.sample_params.guidance.txt_cfg=r->model==QUENDERIN_DIFFUSION_FLUX3_KLEIN?1.0f:3.0f;
        params.sample_params.flow_shift=r->model==QUENDERIN_DIFFUSION_FLUX3_KLEIN?6.93f:5.0f;
        std::vector<sd_image_t>references;references.reserve(r->reference_count);
        for(size_t i=0;i<r->reference_count;++i){const auto&im=r->reference_images[i];references.push_back({im.width,im.height,im.channels,const_cast<uint8_t*>(im.pixels)});}
        params.ref_images=references.empty()?nullptr:references.data();params.ref_images_count=static_cast<int>(references.size());
        Images images;bool success=generate_image(context,&params,&images.data,&images.count);
        if(engine->cancelled.load())fail(QUENDERIN_DIFFUSION_CANCELLED,"Image generation was cancelled.");
        if(!success || images.count!=1 || !images.data || images.data[0].width!=r->width || images.data[0].height!=r->height)
            fail(QUENDERIN_DIFFUSION_GENERATION_FAILED,"The local runtime did not return exactly one image of the requested size.");
        auto encoded=png(images.data[0]);
        if(engine->cancelled.load())fail(QUENDERIN_DIFFUSION_CANCELLED,"Image generation was cancelled.");
        save_new(r->output_path,encoded);return QUENDERIN_DIFFUSION_OK;
    }catch(const Error&e){copy_error(error,size,e.message.c_str());return e.status;}
    catch(...){copy_error(error,size,"Local image generation failed.");return QUENDERIN_DIFFUSION_INTERNAL;}
}
}
