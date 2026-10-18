#include "quenderin_vision.h"
#ifdef FIXTURE_JNI
#include <jni.h>
#endif
#include <atomic>
#include <chrono>
#include <cstring>
#include <string>
#include <thread>
#ifndef FIXTURE_VISION_REVISION
#error Fixture must use exact lock identities
#endif
struct quenderin_vision { std::atomic<bool> cancelled{false}; bool loaded = false; };
static std::atomic<int> active{0}, created{0}, freed{0};
extern "C" {
uint32_t quenderin_vision_runtime_abi() { return 1; }
const char* quenderin_vision_runtime_revision() { return FIXTURE_VISION_REVISION; }
const char* quenderin_vision_patch_sha256() { return FIXTURE_VISION_SHA; }
quenderin_vision* quenderin_vision_create() { ++created; return new quenderin_vision; }
int quenderin_vision_load(quenderin_vision* h, const quenderin_vision_load_options* o) {
    if (!h || h->cancelled || !o || o->abi != 1 || o->context_size != 4096 || o->threads < 1 || o->threads > 8
        || std::strcmp(o->model_id, "minicpm-v47-1b") || !o->model_path || !o->projector_path
        || std::strcmp(o->model_path, o->projector_path) == 0) return 1;
    h->loaded = true; return 0;
}
int quenderin_vision_generate(quenderin_vision* h, const quenderin_vision_request* r, quenderin_vision_output cb, void* user) {
    if (!h || !h->loaded || !r || r->abi != 1 || r->max_tokens != 512 || !r->image_path || !r->prompt || !cb) return 1;
    ++active;
    if (!std::strcmp(r->prompt, "BLOCK")) {
        for (int i = 0; i < 5000 && !h->cancelled; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        --active; return 1;
    }
    const std::string prompt(r->prompt);
    const std::string result = prompt == "Unicode 🌲" ? "Tree 🌲 < safe" : "Wrong UTF-8";
    const int ok = cb(result.data(), result.size(), user);
    --active; return ok && !h->cancelled ? 0 : 1;
}
void quenderin_vision_cancel(quenderin_vision* h) { h->cancelled = true; }
const char* quenderin_vision_last_error(const quenderin_vision*) { return "Fixture vision operation cancelled or invalid"; }
uint32_t quenderin_vision_generated_tokens(const quenderin_vision*) { return 7; }
void quenderin_vision_free(quenderin_vision* h) { if (active) std::terminate(); ++freed; delete h; }
int qv_fixture_active() { return active; }
int qv_fixture_created() { return created; }
int qv_fixture_freed() { return freed; }
void ggml_backend_load_all_from_path(const char*) {}
#ifdef FIXTURE_JNI
JNIEXPORT jint JNICALL Java_ai_quenderin_core_VisionFixture_active(JNIEnv*, jclass) { return active; }
JNIEXPORT jint JNICALL Java_ai_quenderin_core_VisionFixture_balance(JNIEnv*, jclass) { return created - freed; }
#endif
}
