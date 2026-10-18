#include "quenderin_vision.h"
#include "vision_models.generated.h"
#include "vision_safety.h"
#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"
extern "C" {
#include "hash/sha256/sha256.h"
}
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>
#ifndef QUENDERIN_VISION_REVISION
#error Compile with the verified Prism revision and source-patch digest
#endif
#ifndef QUENDERIN_VISION_PATCH_SHA256
#error Compile with the verified vision source-patch digest
#endif
using clock_type = std::chrono::steady_clock;
namespace fs = std::filesystem;
struct quenderin_vision {
    std::mutex mutex;
    std::atomic<bool> cancelled{false};
    clock_type::time_point deadline = clock_type::time_point::max();
    std::string error;
    const qv_model_descriptor * descriptor = nullptr;
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    mtmd_context * projector = nullptr;
    uint32_t context_size = 0, tokens = 0;
    bool stopped() const { return cancelled.load(std::memory_order_relaxed) || clock_type::now() >= deadline; }
    void check() const { if (stopped()) throw std::runtime_error("Vision request cancelled or reached its time limit"); }
    void unload() {
        if (projector) mtmd_free(projector);
        if (context) llama_free(context);
        if (model) llama_model_free(model);
        projector = nullptr; context = nullptr; model = nullptr; descriptor = nullptr; tokens = 0;
    }
    ~quenderin_vision() { unload(); }
};
namespace {
static std::once_flag backend_once;
static bool abort_eval(void * user) { return static_cast<quenderin_vision *>(user)->stopped(); }
static bool load_progress(float, void * user) { return !abort_eval(user); }
static bool eval_progress(ggml_tensor *, bool ask, void * user) { return ask || !abort_eval(user); }
static fs::path regular(const char * value) {
    if (!value || !*value || std::strlen(value) > 16384) throw std::runtime_error("Missing or excessive file path");
    fs::path p = fs::u8path(value);
    if (!p.is_absolute() || fs::is_symlink(fs::symlink_status(p)) || !fs::is_regular_file(p)) throw std::runtime_error("Vision files must be absolute regular files, without symlinks");
    return p;
}
static void verify_artifact(quenderin_vision & state, const fs::path & path, const qv_artifact & expected) {
    const auto size = fs::file_size(path); const auto modified = fs::last_write_time(path);
    if (size != expected.bytes) throw std::runtime_error("Pinned model or projector byte count does not match");
    std::ifstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("Cannot open pinned model or projector");
    sha256_t hash; sha256_init(&hash);
    std::vector<unsigned char> buffer(1024 * 1024); uint64_t read = 0;
    while (file) {
        state.check();
        file.read(reinterpret_cast<char *>(buffer.data()), std::streamsize(buffer.size()));
        const auto n = file.gcount();
        if (n > 0) { read += uint64_t(n); if (read > expected.bytes) throw std::runtime_error("Artifact grew during verification"); sha256_update(&hash, buffer.data(), size_t(n)); }
    }
    if (!file.eof() || read != size || fs::is_symlink(fs::symlink_status(path)) || fs::file_size(path) != size || fs::last_write_time(path) != modified) throw std::runtime_error("Artifact changed or could not be read completely");
    unsigned char bytes[32]; sha256_final(&hash, bytes);
    const char hex[] = "0123456789abcdef"; std::string actual;
    for (auto b : bytes) { actual += hex[b >> 4]; actual += hex[b & 15]; }
    if (actual != expected.sha256) throw std::runtime_error("Pinned model or projector SHA-256 does not match");
}
static std::string token_piece(const llama_vocab * vocab, llama_token token) {
    std::vector<char> buffer(256);
    int32_t n = llama_token_to_piece(vocab, token, buffer.data(), int32_t(buffer.size()), 0, true);
    if (n < 0) { if (n < -65536) throw std::runtime_error("Oversized output token"); buffer.resize(size_t(-n)); n = llama_token_to_piece(vocab, token, buffer.data(), int32_t(buffer.size()), 0, true); }
    if (n < 0 || size_t(n) > buffer.size()) throw std::runtime_error("Could not decode output token");
    return std::string(buffer.data(), size_t(n));
}
}
uint32_t quenderin_vision_runtime_abi(void) { return quenderin_vision_mtmd_runtime_abi() == 1 ? 1 : 0; }
const char * quenderin_vision_runtime_revision(void) { return QUENDERIN_VISION_REVISION; }
const char * quenderin_vision_patch_sha256(void) { return QUENDERIN_VISION_PATCH_SHA256; }
quenderin_vision * quenderin_vision_create(void) { try { return new quenderin_vision; } catch (...) { return nullptr; } }
int quenderin_vision_load(quenderin_vision * s, const quenderin_vision_load_options * o) {
    if (!s) return 1;
    std::lock_guard<std::mutex> guard(s->mutex);
    try {
        s->error.clear(); s->deadline = clock_type::now() + std::chrono::minutes(20); s->unload();
        if (!o || o->abi != 1 || !o->model_id || o->context_size < 1024 || o->context_size > 8192 || o->threads < 1 || o->threads > 16 || quenderin_vision_runtime_abi() != 1) throw std::runtime_error("Invalid vision ABI, model or load limits");
        for (const auto & descriptor : qv_models) if (!std::strcmp(descriptor.id, o->model_id)) s->descriptor = &descriptor;
        if (!s->descriptor) throw std::runtime_error("Vision model is not in the pinned manifest");
        const auto model_path = regular(o->model_path), projector_path = regular(o->projector_path);
        if (fs::equivalent(model_path, projector_path)) throw std::runtime_error("Main model and projector must be distinct files");
        const auto model_mtime = fs::last_write_time(model_path), projector_mtime = fs::last_write_time(projector_path);
        verify_artifact(*s, model_path, s->descriptor->model); verify_artifact(*s, projector_path, s->descriptor->projector); s->check();
        std::call_once(backend_once, [] { llama_backend_init(); ggml_backend_load_all(); });
        auto mp = llama_model_default_params();
        mp.n_gpu_layers = -1; // use a compiled GPU backend when available, otherwise CPU
        mp.progress_callback = load_progress; mp.progress_callback_user_data = s;
        s->model = llama_model_load_from_file(o->model_path, mp);
        if (!s->model) throw std::runtime_error("Could not load verified vision text model");
        s->check();
        auto cp = llama_context_default_params();
        cp.n_ctx = o->context_size; cp.n_batch = std::min<uint32_t>(256, cp.n_ctx); cp.n_ubatch = cp.n_batch;
        cp.n_threads = int(o->threads); cp.n_threads_batch = int(o->threads); cp.n_seq_max = 1;
        cp.abort_callback = abort_eval; cp.abort_callback_data = s;
        cp.cb_eval = eval_progress; cp.cb_eval_user_data = s;
        s->context = llama_init_from_model(s->model, cp);
        if (!s->context) throw std::runtime_error("Could not allocate bounded vision context");
        auto vp = mtmd_context_params_default();
        vp.use_gpu = true; vp.n_threads = int(o->threads); vp.warmup = false; vp.print_timings = false;
        vp.image_max_tokens = 2048; vp.batch_max_tokens = 2048;
        vp.progress_callback = load_progress; vp.progress_callback_user_data = s;
        vp.cb_eval = eval_progress; vp.cb_eval_user_data = s;
        s->projector = mtmd_init_from_file(o->projector_path, s->model, vp);
        if (!s->projector || !mtmd_support_vision(s->projector)) throw std::runtime_error("Could not load verified image projector");
        if (fs::is_symlink(fs::symlink_status(model_path)) || fs::is_symlink(fs::symlink_status(projector_path)) || fs::file_size(model_path) != s->descriptor->model.bytes || fs::file_size(projector_path) != s->descriptor->projector.bytes || fs::last_write_time(model_path) != model_mtime || fs::last_write_time(projector_path) != projector_mtime) throw std::runtime_error("Verified model artifacts changed while loading");
        s->context_size = o->context_size; s->check(); return 0;
    } catch (const fs::filesystem_error &) { s->error = "Vision model files are unavailable or changed"; s->unload(); return 1; }
      catch (const std::exception & error) { s->error = error.what(); s->unload(); return 1; }
      catch (...) { s->error = "Vision model load failed"; s->unload(); return 1; }
}
int quenderin_vision_generate(quenderin_vision * s, const quenderin_vision_request * request, quenderin_vision_output output, void * user) {
    if (!s) return 1;
    std::lock_guard<std::mutex> guard(s->mutex);
    try {
        s->error.clear(); s->tokens = 0; s->deadline = clock_type::now() + std::chrono::minutes(5);
        if (!request || request->abi != 1 || !request->prompt || !request->image_path || !output || request->max_tokens < 1 || request->max_tokens > 1024 || !s->context || !s->projector || !s->descriptor) throw std::runtime_error("Invalid vision request or model is not loaded");
        qv::validate_prompt(request->prompt);
        const auto path = regular(request->image_path); const auto size = fs::file_size(path);
        if (!size || size > qv::max_image_bytes) throw std::runtime_error("Image must be at most 8 MiB");
        std::ifstream file(path, std::ios::binary); std::vector<unsigned char> encoded(size);
        if (!file.read(reinterpret_cast<char *>(encoded.data()), std::streamsize(size)) || file.peek() != std::char_traits<char>::eof()) throw std::runtime_error("Image changed or could not be read completely");
        const auto image = qv::decode_still(encoded); s->check();
        std::unique_ptr<mtmd_bitmap, decltype(&mtmd_bitmap_free)> bitmap(mtmd_bitmap_init(image.width, image.height, image.rgb.data()), mtmd_bitmap_free);
        if (!bitmap) throw std::runtime_error("Could not allocate image bitmap");
        mtmd_bitmap_set_mergeable(bitmap.get(), false);
        std::unique_ptr<mtmd_input_chunks, decltype(&mtmd_input_chunks_free)> chunks(mtmd_input_chunks_init(), mtmd_input_chunks_free);
        if (!chunks) throw std::runtime_error("Could not allocate image chunks");
        const auto prompt = qv::render_prompt(s->descriptor->family, mtmd_get_marker(s->projector), request->prompt);
        mtmd_input_text text{prompt.data(), prompt.size(), true, true}; const mtmd_bitmap * bitmaps[] = {bitmap.get()};
        if (mtmd_tokenize(s->projector, chunks.get(), &text, bitmaps, 1)) throw std::runtime_error("Image prompt tokenization failed");
        const auto n_tokens = mtmd_helper_get_n_tokens(chunks.get()); const auto n_pos = mtmd_helper_get_n_pos(chunks.get());
        if (!n_tokens || n_pos <= 0 || n_tokens + request->max_tokens >= s->context_size || uint64_t(n_pos) + request->max_tokens >= s->context_size) throw std::runtime_error("Image and prompt exceed the bounded context; use a smaller image or shorter prompt");
        llama_memory_clear(llama_get_memory(s->context), true); s->check();
        llama_pos position = 0;
        if (mtmd_helper_eval_chunks(s->projector, s->context, chunks.get(), 0, 0, 256, true, &position)) throw std::runtime_error("Image encoding or prompt evaluation failed");
        const auto * vocab = llama_model_get_vocab(s->model);
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(llama_sampler_init_greedy(), llama_sampler_free);
        if (!sampler) throw std::runtime_error("Could not allocate bounded sampler");
        std::string raw;
        for (uint32_t i = 0; i < request->max_tokens; ++i) {
            s->check(); llama_token token = llama_sampler_sample(sampler.get(), s->context, -1);
            if (llama_vocab_is_eog(vocab, token)) break;
            raw += token_piece(vocab, token); ++s->tokens;
            if (raw.size() > 65536) throw std::runtime_error("Vision answer exceeded byte limit");
            if (position >= llama_pos(s->context_size - 1)) throw std::runtime_error("Vision answer reached context limit");
            auto batch = llama_batch_get_one(&token, 1);
            // The one-token helper advances the existing sequence position.
            if (llama_decode(s->context, batch)) throw std::runtime_error("Vision answer decoding failed");
            ++position;
        }
        s->check(); const auto answer = qv::visible_answer(raw);
        if (answer.empty()) throw std::runtime_error("Model produced no visible answer within the output limit");
        if (!output(answer.data(), answer.size(), user)) { s->cancelled = true; throw std::runtime_error("Vision output cancelled"); }
        llama_memory_clear(llama_get_memory(s->context), true); return 0;
    } catch (const fs::filesystem_error &) { s->error = "Vision image file is unavailable or changed"; if (s->context) llama_memory_clear(llama_get_memory(s->context), true); return 1; }
      catch (const std::exception & error) { s->error = error.what(); if (s->context) llama_memory_clear(llama_get_memory(s->context), true); return 1; }
      catch (...) { s->error = "Vision request failed"; if (s->context) llama_memory_clear(llama_get_memory(s->context), true); return 1; }
}
void quenderin_vision_cancel(quenderin_vision * s) { if (s) s->cancelled.store(true, std::memory_order_relaxed); }
const char * quenderin_vision_last_error(const quenderin_vision * s) { return s ? s->error.c_str() : "Vision handle is unavailable"; }
uint32_t quenderin_vision_generated_tokens(const quenderin_vision * s) { return s ? s->tokens : 0; }
void quenderin_vision_free(quenderin_vision * s) { delete s; }
