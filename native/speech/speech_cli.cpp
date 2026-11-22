#include "quenderin_speech.h"
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
volatile std::sig_atomic_t interrupted = 0;
void signal_handler(int) { interrupted = 1; }

std::string json(const std::string &s) {
    std::string out = "\"";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') { out += '\\'; out += static_cast<char>(c); }
        else if (c < 32) {
            char value[7];
            std::snprintf(value, sizeof(value), "\\u%04x", c);
            out += value;
        } else {
            out += static_cast<char>(c);
        }
    }
    return out + '"';
}

uint32_t number(const std::string &value) {
    size_t n = 0;
    auto parsed = std::stoul(value, &n);
    if (n != value.size() || parsed > 0xffffffffUL) throw std::runtime_error("Invalid numeric option.");
    return static_cast<uint32_t>(parsed);
}
} // namespace

int run(int argc, char **argv) {
    try {
        if (argc == 2 && std::string(argv[1]) == "--version") {
            std::printf("{\"abiVersion\":%u,\"revision\":%s}\n",
                        quenderin_speech_abi(), json(quenderin_speech_revision()).c_str());
            return 0;
        }
        const std::map<std::string, bool> value_flags = {
            {"--model", true}, {"--vad", true}, {"--wav", true}, {"--language", true},
            {"--prompt", true}, {"--vocab", true}, {"--threads", true}
        };
        const std::map<std::string, bool> bool_flags = {{"--translate", true}, {"--timestamps", true}};
        std::map<std::string, std::string> args;
        bool translate = false;
        bool timestamps = false;
        for (int i = 1; i < argc;) {
            std::string key = argv[i];
            if (bool_flags.count(key)) {
                if (key == "--translate") translate = true;
                else timestamps = true;
                ++i;
                continue;
            }
            if (!value_flags.count(key) || i + 1 >= argc || args.count(key)) {
                throw std::runtime_error("Unknown, duplicate or missing speech CLI option.");
            }
            args[key] = argv[i + 1];
            i += 2;
        }
        for (auto key : {"--model", "--wav"}) {
            if (!args.count(key)) throw std::runtime_error("Missing required speech CLI option.");
        }
        std::vector<std::string> vocab_terms;
        std::vector<const char *> vocab_ptrs;
        if (args.count("--vocab") && !args["--vocab"].empty()) {
            const std::string &raw = args["--vocab"];
            size_t start = 0;
            while (start <= raw.size()) {
                size_t comma = raw.find(',', start);
                std::string term = comma == std::string::npos ? raw.substr(start) : raw.substr(start, comma - start);
                if (!term.empty()) vocab_terms.push_back(term);
                if (comma == std::string::npos) break;
                start = comma + 1;
            }
            for (const auto &t : vocab_terms) vocab_ptrs.push_back(t.c_str());
        }

        quenderin_speech_request req{};
        req.abi_version = QUENDERIN_SPEECH_ABI;
        req.struct_size = sizeof(req);
        req.model_path = args["--model"].c_str();
        req.vad_path = args.count("--vad") ? args["--vad"].c_str() : nullptr;
        req.wav_path = args["--wav"].c_str();
        req.sample_rate = 16000;
        req.language = args.count("--language") ? args["--language"].c_str() : "en";
        req.prompt = args.count("--prompt") ? args["--prompt"].c_str() : nullptr;
        req.vocabulary = vocab_ptrs.empty() ? nullptr : vocab_ptrs.data();
        req.vocabulary_count = static_cast<uint32_t>(vocab_ptrs.size());
        req.threads = args.count("--threads") ? number(args["--threads"]) : 4;
        req.translate = translate;
        req.timestamps = timestamps;

        auto *engine = quenderin_speech_create();
        if (!engine) throw std::runtime_error("Unable to create speech engine.");
        std::signal(SIGINT, signal_handler);
        std::signal(SIGTERM, signal_handler);
        std::atomic<bool> done{false};
        std::thread monitor([&] {
            while (!done.load()) {
                if (interrupted) quenderin_speech_cancel(engine);
                std::this_thread::sleep_for(std::chrono::milliseconds(25));
            }
        });
        quenderin_speech_result result{};
        char error[512]{};
        auto status = quenderin_speech_transcribe(engine, &req, &result, error, sizeof(error));
        done = true;
        monitor.join();
        quenderin_speech_destroy(engine);
        if (status != QUENDERIN_SPEECH_OK) {
            quenderin_speech_result_free(&result);
            std::printf("{\"ok\":false,\"status\":%d,\"error\":%s}\n", status, json(error).c_str());
            return static_cast<int>(status);
        }
        std::printf(
            "{\"ok\":true,\"text\":%s,\"language\":%s,\"backend\":%s,\"durationMs\":%lld,\"truncated\":%s,\"segments\":%s}\n",
            json(result.text ? result.text : "").c_str(),
            json(result.language ? result.language : "").c_str(),
            json(result.backend ? result.backend : "").c_str(),
            static_cast<long long>(result.duration_ms),
            result.truncated ? "true" : "false",
            result.segments_json ? result.segments_json : "[]");
        quenderin_speech_result_free(&result);
        return 0;
    } catch (const std::exception &e) {
        std::printf("{\"ok\":false,\"status\":1,\"error\":%s}\n", json(e.what()).c_str());
        return 1;
    }
}

#if defined(_WIN32)
int wmain(int argc, wchar_t **wide_argv) {
    try {
        std::vector<std::string> values;
        values.reserve(argc);
        for (int i = 0; i < argc; ++i) {
            int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide_argv[i], -1, nullptr, 0, nullptr, nullptr);
            if (length <= 0) throw std::runtime_error("Invalid Unicode command-line argument.");
            std::string value(static_cast<size_t>(length), '\0');
            if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide_argv[i], -1, value.data(), length, nullptr, nullptr)) {
                throw std::runtime_error("Unable to read Unicode command-line argument.");
            }
            value.resize(static_cast<size_t>(length) - 1);
            values.push_back(std::move(value));
        }
        std::vector<char *> argv;
        argv.reserve(values.size());
        for (auto &value : values) argv.push_back(value.data());
        return run(argc, argv.data());
    } catch (const std::exception &e) {
        std::printf("{\"ok\":false,\"status\":1,\"error\":%s}\n", json(e.what()).c_str());
        return 1;
    }
}
#else
int main(int argc, char **argv) { return run(argc, argv); }
#endif
