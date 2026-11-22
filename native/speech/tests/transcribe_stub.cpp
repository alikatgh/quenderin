#include "transcribe.h"
#include <chrono>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

struct transcribe_model {
    std::string path;
};

struct transcribe_session {
    transcribe_model *model = nullptr;
    transcribe_abort_callback abort_cb = nullptr;
    void *abort_user = nullptr;
    bool aborted = false;
    std::string text;
    std::string language;
};

extern "C" {
void transcribe_model_load_params_init(struct transcribe_model_load_params *p) {
    if (!p) return;
    p->struct_size = sizeof(*p);
    p->backend = TRANSCRIBE_BACKEND_AUTO;
    p->device = nullptr;
    p->no_mmap = false;
}

void transcribe_session_params_init(struct transcribe_session_params *p) {
    if (!p) return;
    p->struct_size = sizeof(*p);
    p->n_threads = 0;
    p->kv_type = TRANSCRIBE_KV_TYPE_AUTO;
    p->n_ctx = 0;
}

void transcribe_run_params_init(struct transcribe_run_params *p) {
    if (!p) return;
    std::memset(p, 0, sizeof(*p));
    p->struct_size = sizeof(*p);
    p->task = TRANSCRIBE_TASK_TRANSCRIBE;
    p->timestamps = TRANSCRIBE_TIMESTAMPS_AUTO;
}

void transcribe_segment_init(struct transcribe_segment *out) {
    if (!out) return;
    std::memset(out, 0, sizeof(*out));
    out->struct_size = sizeof(*out);
}

const char *transcribe_status_string(int status) {
    switch (status) {
        case TRANSCRIBE_OK: return "ok";
        case TRANSCRIBE_ERR_ABORTED: return "aborted";
        case TRANSCRIBE_ERR_FILE_NOT_FOUND: return "file not found";
        default: return "speech stub error";
    }
}

transcribe_status transcribe_model_load_file(const char *path, const struct transcribe_model_load_params *params, struct transcribe_model **out_model) {
    if (!out_model || !path || (params && params->struct_size < sizeof(*params))) return TRANSCRIBE_ERR_INVALID_ARG;
    *out_model = nullptr;
    if (std::strstr(path, "load-fail")) return TRANSCRIBE_ERR_GGUF;
    *out_model = new transcribe_model{path};
    return TRANSCRIBE_OK;
}

void transcribe_model_free(struct transcribe_model *model) { delete model; }
const char *transcribe_model_backend(const struct transcribe_model *model) { return model ? "cpu-fixture" : ""; }
bool transcribe_model_supports(const struct transcribe_model *model, transcribe_feature) { return model != nullptr; }

transcribe_status transcribe_session_init(struct transcribe_model *model, const struct transcribe_session_params *params, struct transcribe_session **out_session) {
    if (!model || !out_session || (params && params->struct_size < sizeof(*params))) return TRANSCRIBE_ERR_INVALID_ARG;
    *out_session = new transcribe_session{model};
    return TRANSCRIBE_OK;
}

void transcribe_session_free(struct transcribe_session *session) { delete session; }

void transcribe_set_abort_callback(struct transcribe_session *session, transcribe_abort_callback cb, void *user_data) {
    if (!session) return;
    session->abort_cb = cb;
    session->abort_user = user_data;
}

transcribe_status transcribe_run(struct transcribe_session *session, const float *pcm, int n_samples, const struct transcribe_run_params *params) {
    if (!session || !pcm || n_samples <= 0) return TRANSCRIBE_ERR_INVALID_ARG;
    session->aborted = false;
    if (std::strstr(session->model->path.c_str(), "slow-cancel")) {
        for (int i = 0; i < 40; ++i) {
            if (session->abort_cb && session->abort_cb(session->abort_user)) {
                session->aborted = true;
                return TRANSCRIBE_ERR_ABORTED;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    }
    if (session->abort_cb && session->abort_cb(session->abort_user)) {
        session->aborted = true;
        return TRANSCRIBE_ERR_ABORTED;
    }
    session->language = (params && params->language) ? params->language : "en";
    session->text = "Quenderin local speech fixture";
    if (params && params->vocabulary && params->n_vocabulary > 0 && params->vocabulary[0]) {
        session->text += std::string(": ") + params->vocabulary[0];
    }
    return TRANSCRIBE_OK;
}

bool transcribe_was_aborted(const struct transcribe_session *session) { return session ? session->aborted : false; }
bool transcribe_was_truncated(const struct transcribe_session *) { return false; }
const char *transcribe_full_text(const struct transcribe_session *session) { return session ? session->text.c_str() : ""; }
const char *transcribe_detected_language(const struct transcribe_session *session) { return session ? session->language.c_str() : ""; }
int transcribe_n_segments(const struct transcribe_session *session) { return (session && !session->text.empty()) ? 1 : 0; }
transcribe_status transcribe_get_segment(const struct transcribe_session *session, int i, struct transcribe_segment *out) {
    if (!out || out->struct_size < sizeof(*out)) return TRANSCRIBE_ERR_INVALID_ARG;
    if (!session || i != 0 || session->text.empty()) return TRANSCRIBE_OK;
    out->t0_ms = 0;
    out->t1_ms = 1000;
    out->text = session->text.c_str();
    out->speaker_id = 0;
    return TRANSCRIBE_OK;
}
}
