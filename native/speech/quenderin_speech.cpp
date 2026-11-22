#include "quenderin_speech.h"
#include "transcribe.h"
#include <algorithm>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
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

#ifndef QUENDERIN_SPEECH_REVISION
#error Build must identify the exact pinned transcribe.cpp revision
#endif

struct quenderin_speech_engine {
    std::mutex state;
    bool running = false;
    std::atomic<bool> cancelled{false};
};

namespace {
std::mutex process_transcription;
constexpr size_t MAX_AUDIO_BYTES = 64u * 1024u * 1024u;
constexpr uint32_t EXPECTED_SAMPLE_RATE = 16000u;

using Status = quenderin_speech_status;
struct Error { Status status; std::string message; };
[[noreturn]] void fail(Status status, const char *message) { throw Error{status, message}; }

void copy_error(char *output, size_t capacity, const char *message) {
    if (output && capacity) std::snprintf(output, capacity, "%s", message ? message : "");
}

char *dup_cstr(const std::string &value) {
    char *out = static_cast<char *>(std::malloc(value.size() + 1));
    if (!out) return nullptr;
    std::memcpy(out, value.data(), value.size());
    out[value.size()] = '\0';
    return out;
}

size_t text_length(const char *text, size_t maximum, bool required) {
    if (!text) { if (required) fail(QUENDERIN_SPEECH_INVALID, "Missing required text or path."); return 0; }
    size_t size = 0;
    while (size <= maximum && text[size]) ++size;
    if (size > maximum || (required && !size)) fail(QUENDERIN_SPEECH_INVALID, "Text or path length is invalid.");
    return size;
}

std::filesystem::path canonical_regular_file(const char *value, const char *label, const char *magic4 = nullptr) {
    size_t size = text_length(value, 4096, true);
    for (size_t i = 0; i < size; ++i) {
        if (static_cast<unsigned char>(value[i]) < 32) fail(QUENDERIN_SPEECH_INVALID, "Path contains a control character.");
    }
    if (std::strstr(value, "://")) fail(QUENDERIN_SPEECH_INVALID, "URI schemes are not supported.");
    auto path = std::filesystem::u8path(value);
    if (!path.is_absolute() || path.lexically_normal() != path) {
        fail(QUENDERIN_SPEECH_INVALID, label);
    }
    std::error_code ec;
    auto st = std::filesystem::symlink_status(path, ec);
    if (ec || !std::filesystem::is_regular_file(st) || std::filesystem::canonical(path, ec) != path || ec) {
        fail(QUENDERIN_SPEECH_INVALID, "Speech file must be an existing regular local file without symlinks.");
    }
    if (magic4) {
        std::ifstream f(path, std::ios::binary);
        char buf[4]{};
        f.read(buf, 4);
        if (!f || std::memcmp(buf, magic4, 4) != 0) {
            fail(QUENDERIN_SPEECH_INVALID, "Input file header does not match expected format.");
        }
    }
    return path;
}

std::string json_escape(const char *s) {
    std::string out = "\"";
    if (s) {
        for (const unsigned char *p = reinterpret_cast<const unsigned char *>(s); *p; ++p) {
            unsigned char c = *p;
            if (c == '"' || c == '\\') { out += '\\'; out += static_cast<char>(c); }
            else if (c < 32) {
                char buf[7];
                std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    out += '"';
    return out;
}

uint16_t u16_le(const uint8_t *p) { return static_cast<uint16_t>(p[0] | (static_cast<uint16_t>(p[1]) << 8)); }
uint32_t u32_le(const uint8_t *p) {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8)
         | (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

std::vector<float> read_wav_16k_mono(const std::filesystem::path &wav_path, bool decode_pcm) {
    std::error_code ec;
    auto size = std::filesystem::file_size(wav_path, ec);
    if (ec || size < 44 || size > MAX_AUDIO_BYTES) {
        fail(QUENDERIN_SPEECH_INVALID, "WAV file size must be between 44 bytes and 64 MiB.");
    }
    std::vector<uint8_t> bytes(static_cast<size_t>(size));
    std::ifstream in(wav_path, std::ios::binary);
    if (!in.read(reinterpret_cast<char *>(bytes.data()), static_cast<std::streamsize>(bytes.size()))) {
        fail(QUENDERIN_SPEECH_INVALID, "Unable to read WAV audio bytes.");
    }
    if (std::memcmp(bytes.data(), "RIFF", 4) != 0 || std::memcmp(bytes.data() + 8, "WAVE", 4) != 0) {
        fail(QUENDERIN_SPEECH_INVALID, "Audio must be a RIFF WAVE file.");
    }
    uint16_t format = 0, channels = 0, bits = 0;
    uint32_t rate = 0;
    size_t data_offset = 0, data_size = 0;
    size_t pos = 12;
    while (pos + 8 <= bytes.size()) {
        uint32_t chunk_size = u32_le(bytes.data() + pos + 4);
        size_t payload = pos + 8;
        if (payload + chunk_size > bytes.size()) fail(QUENDERIN_SPEECH_INVALID, "Truncated WAV chunk.");
        if (std::memcmp(bytes.data() + pos, "fmt ", 4) == 0 && chunk_size >= 16) {
            format = u16_le(bytes.data() + payload);
            channels = u16_le(bytes.data() + payload + 2);
            rate = u32_le(bytes.data() + payload + 4);
            bits = u16_le(bytes.data() + payload + 14);
        } else if (std::memcmp(bytes.data() + pos, "data", 4) == 0) {
            data_offset = payload;
            data_size = chunk_size;
            break;
        }
        pos = payload + chunk_size + (chunk_size & 1u);
    }
    if (format != 1 || channels != 1 || rate != EXPECTED_SAMPLE_RATE || bits != 16 || data_size < 2) {
        fail(QUENDERIN_SPEECH_INVALID, "WAV audio must be non-empty 16 kHz mono 16-bit PCM.");
    }
    if (!decode_pcm) return {};
    size_t count = data_size / 2;
    std::vector<float> pcm(count);
    for (size_t i = 0; i < count; ++i) {
        int16_t s = static_cast<int16_t>(u16_le(bytes.data() + data_offset + i * 2));
        pcm[i] = static_cast<float>(s) / 32768.0f;
    }
    return pcm;
}

std::vector<float> decode_wav_16k_mono(const std::filesystem::path &wav_path) {
    return read_wav_16k_mono(wav_path, true);
}

void validate_impl(const quenderin_speech_request *r) {
    if (!r || r->abi_version != QUENDERIN_SPEECH_ABI || r->struct_size != sizeof(*r)) {
        fail(QUENDERIN_SPEECH_INVALID, "Speech runtime ABI mismatch.");
    }
    if (!r->threads || r->threads > 8 || r->sample_rate != EXPECTED_SAMPLE_RATE) {
        fail(QUENDERIN_SPEECH_INVALID, "Speech threads or sample rate exceed bounds.");
    }
    if (r->vocabulary_count > 100 || (r->vocabulary_count && !r->vocabulary)) {
        fail(QUENDERIN_SPEECH_INVALID, "Speech vocabulary exceeds 100 terms.");
    }
    for (uint32_t i = 0; i < r->vocabulary_count; ++i) {
        text_length(r->vocabulary[i], 256, true);
    }
    text_length(r->language, 32, false);
    text_length(r->prompt, 8192, false);
    canonical_regular_file(r->model_path, "A canonical local speech model path is required.");
    if (r->vad_path && *r->vad_path) {
        canonical_regular_file(r->vad_path, "A canonical local VAD model path is required.", "GGUF");
    }
    bool has_wav = r->wav_path && *r->wav_path;
    bool has_pcm = r->pcm_f32 != nullptr && r->pcm_samples > 0;
    if (has_wav == has_pcm) {
        fail(QUENDERIN_SPEECH_INVALID, "Provide exactly one of wav_path or pcm_f32.");
    }
    if (has_wav) {
        auto wav = canonical_regular_file(r->wav_path, "A canonical local WAV path is required.", "RIFF");
        if (wav.extension() != ".wav" && wav.extension() != ".WAV") {
            fail(QUENDERIN_SPEECH_INVALID, "Audio path must have a .wav extension.");
        }
        read_wav_16k_mono(wav, false);
    } else {
        if (r->pcm_samples > MAX_AUDIO_BYTES / sizeof(float)) {
            fail(QUENDERIN_SPEECH_INVALID, "Audio sample buffer exceeds 64 MiB bound.");
        }
        for (size_t i = 0; i < r->pcm_samples; ++i) {
            if (!std::isfinite(r->pcm_f32[i])) {
                fail(QUENDERIN_SPEECH_INVALID, "PCM audio contains non-finite samples.");
            }
        }
    }
}

bool abort_poll(void *user_data) {
    auto *engine = static_cast<quenderin_speech_engine *>(user_data);
    return engine && engine->cancelled.load();
}

void free_result_fields(quenderin_speech_result *r) {
    if (!r) return;
    std::free(r->text); r->text = nullptr;
    std::free(r->language); r->language = nullptr;
    std::free(r->backend); r->backend = nullptr;
    std::free(r->segments_json); r->segments_json = nullptr;
    r->duration_ms = 0;
    r->truncated = false;
    r->aborted = false;
}
} // namespace

extern "C" {
uint32_t quenderin_speech_abi(void) { return QUENDERIN_SPEECH_ABI; }
const char *quenderin_speech_revision(void) { return QUENDERIN_SPEECH_REVISION; }

quenderin_speech_engine *quenderin_speech_create(void) {
    try { return new quenderin_speech_engine; } catch (...) { return nullptr; }
}

Status quenderin_speech_destroy(quenderin_speech_engine *engine) {
    if (!engine) return QUENDERIN_SPEECH_INVALID;
    {
        std::lock_guard<std::mutex> lock(engine->state);
        if (engine->running) return QUENDERIN_SPEECH_BUSY;
    }
    delete engine;
    return QUENDERIN_SPEECH_OK;
}

Status quenderin_speech_cancel(quenderin_speech_engine *engine) {
    if (!engine) return QUENDERIN_SPEECH_INVALID;
    engine->cancelled.store(true);
    return QUENDERIN_SPEECH_OK;
}

Status quenderin_speech_validate(const quenderin_speech_request *request, char *error, size_t error_size) {
    copy_error(error, error_size, "");
    try { validate_impl(request); return QUENDERIN_SPEECH_OK; }
    catch (const Error &e) { copy_error(error, error_size, e.message.c_str()); return e.status; }
    catch (...) { copy_error(error, error_size, "Unable to validate speech request."); return QUENDERIN_SPEECH_INTERNAL; }
}

void quenderin_speech_result_free(quenderin_speech_result *result) {
    free_result_fields(result);
}

Status quenderin_speech_transcribe(
    quenderin_speech_engine *engine, const quenderin_speech_request *r,
    quenderin_speech_result *out, char *error, size_t error_size) {
    copy_error(error, error_size, "");
    if (!engine || !out) { copy_error(error, error_size, "Missing speech engine or output buffer."); return QUENDERIN_SPEECH_INVALID; }
    std::memset(out, 0, sizeof(*out));
    std::unique_lock<std::mutex> global(process_transcription, std::try_to_lock);
    if (!global.owns_lock()) { copy_error(error, error_size, "Another transcription is already running."); return QUENDERIN_SPEECH_BUSY; }
    {
        std::lock_guard<std::mutex> lock(engine->state);
        if (engine->running) return QUENDERIN_SPEECH_BUSY;
        engine->running = true;
    }
    struct Guard {
        quenderin_speech_engine *e;
        struct transcribe_session *session = nullptr;
        struct transcribe_model *model = nullptr;
        ~Guard() {
            if (session) transcribe_session_free(session);
            if (model) transcribe_model_free(model);
            std::lock_guard<std::mutex> lock(e->state);
            e->running = false;
        }
    } guard{engine};

    try {
        if (engine->cancelled.load()) fail(QUENDERIN_SPEECH_CANCELLED, "Speech transcription was cancelled.");
        validate_impl(r);
        std::vector<float> wav_pcm;
        const float *pcm = r->pcm_f32;
        int n_samples = 0;
        if (r->wav_path && *r->wav_path) {
            wav_pcm = decode_wav_16k_mono(std::filesystem::u8path(r->wav_path));
            pcm = wav_pcm.data();
            if (wav_pcm.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
                fail(QUENDERIN_SPEECH_INVALID, "WAV sample count overflow.");
            }
            n_samples = static_cast<int>(wav_pcm.size());
        } else {
            if (r->pcm_samples > static_cast<size_t>(std::numeric_limits<int>::max())) {
                fail(QUENDERIN_SPEECH_INVALID, "PCM sample count overflow.");
            }
            n_samples = static_cast<int>(r->pcm_samples);
        }

        struct transcribe_model_load_params load_params;
        transcribe_model_load_params_init(&load_params);
        load_params.backend = TRANSCRIBE_BACKEND_AUTO;
        if (transcribe_model_load_file(r->model_path, &load_params, &guard.model) != TRANSCRIBE_OK || !guard.model) {
            fail(QUENDERIN_SPEECH_LOAD_FAILED, "Unable to load local speech model.");
        }
        struct transcribe_session_params sess_params;
        transcribe_session_params_init(&sess_params);
        sess_params.n_threads = static_cast<int>(r->threads);
        if (transcribe_session_init(guard.model, &sess_params, &guard.session) != TRANSCRIBE_OK || !guard.session) {
            fail(QUENDERIN_SPEECH_LOAD_FAILED, "Unable to initialize local speech session.");
        }
        transcribe_set_abort_callback(guard.session, abort_poll, engine);

        struct transcribe_run_params run_params;
        transcribe_run_params_init(&run_params);
        run_params.task = r->translate ? TRANSCRIBE_TASK_TRANSLATE : TRANSCRIBE_TASK_TRANSCRIBE;
        run_params.timestamps = r->timestamps ? TRANSCRIBE_TIMESTAMPS_AUTO : TRANSCRIBE_TIMESTAMPS_NONE;
        if (r->language && *r->language && std::strcmp(r->language, "auto") != 0) {
            run_params.language = r->language;
        }
        if (r->prompt && *r->prompt && transcribe_model_supports(guard.model, TRANSCRIBE_FEATURE_CONTEXT_PROMPT)) {
            run_params.prompt = r->prompt;
        }
        if (r->vocabulary_count > 0 && transcribe_model_supports(guard.model, TRANSCRIBE_FEATURE_VOCABULARY)) {
            run_params.vocabulary = r->vocabulary;
            run_params.n_vocabulary = static_cast<int32_t>(r->vocabulary_count);
        }

        transcribe_status st = transcribe_run(guard.session, pcm, n_samples, &run_params);
        if (st == TRANSCRIBE_ERR_ABORTED || transcribe_was_aborted(guard.session) || engine->cancelled.load()) {
            fail(QUENDERIN_SPEECH_CANCELLED, "Speech transcription was cancelled.");
        }
        if (st != TRANSCRIBE_OK && st != TRANSCRIBE_ERR_OUTPUT_TRUNCATED && st != TRANSCRIBE_ERR_OUTPUT_REPETITION) {
            if (st == TRANSCRIBE_ERR_UNSUPPORTED_TASK || st == TRANSCRIBE_ERR_UNSUPPORTED_LANGUAGE || st == TRANSCRIBE_ERR_UNSUPPORTED_TIMESTAMPS) {
                fail(QUENDERIN_SPEECH_UNSUPPORTED, transcribe_status_string(st));
            }
            fail(QUENDERIN_SPEECH_TRANSCRIBE_FAILED, transcribe_status_string(st));
        }

        const char *full = transcribe_full_text(guard.session);
        const char *lang = transcribe_detected_language(guard.session);
        const char *backend = transcribe_model_backend(guard.model);
        out->text = dup_cstr(full ? full : "");
        out->language = dup_cstr((lang && *lang) ? lang : (r->language ? r->language : ""));
        out->backend = dup_cstr(backend ? backend : "");
        out->duration_ms = static_cast<int64_t>((static_cast<double>(n_samples) * 1000.0) / EXPECTED_SAMPLE_RATE);
        out->truncated = transcribe_was_truncated(guard.session);
        out->aborted = transcribe_was_aborted(guard.session);

        std::string segs = "[";
        int n_seg = transcribe_n_segments(guard.session);
        for (int i = 0; i < n_seg; ++i) {
            struct transcribe_segment seg;
            transcribe_segment_init(&seg);
            if (transcribe_get_segment(guard.session, i, &seg) == TRANSCRIBE_OK && seg.text) {
                if (segs.size() > 1) segs += ",";
                segs += "{\"t0Ms\":" + std::to_string(seg.t0_ms) + ",\"t1Ms\":" + std::to_string(seg.t1_ms)
                      + ",\"text\":" + json_escape(seg.text) + "}";
            }
        }
        segs += "]";
        out->segments_json = dup_cstr(segs);
        return QUENDERIN_SPEECH_OK;
    } catch (const Error &e) {
        free_result_fields(out);
        copy_error(error, error_size, e.message.c_str());
        return e.status;
    } catch (...) {
        free_result_fields(out);
        copy_error(error, error_size, "Local speech transcription failed.");
        return QUENDERIN_SPEECH_INTERNAL;
    }
}
}
