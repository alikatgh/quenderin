#include "quenderin_vision.h"
#include "vision_safety.h"
#include "nlohmann/json.hpp"
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
using json = nlohmann::ordered_json;
static void emit(const json & item) { std::cout << item.dump() << '\n' << std::flush; }
static int output(const char * text, size_t bytes, void *) {
    // One final-only answer; parent limits NDJSON to 512 KiB and owns cancellation.
    emit({{"type", "token"}, {"text", std::string(text, bytes)}}); return bool(std::cout);
}
int main(int argc, char ** argv) {
    try {
        if (argc == 2 && std::string(argv[1]) == "--abi") {
            emit({{"abi", quenderin_vision_runtime_abi()}, {"revision", quenderin_vision_runtime_revision()}, {"visionPatchSha256", quenderin_vision_patch_sha256()}});
            return quenderin_vision_runtime_abi() == 1 ? 0 : 1;
        }
        if (argc != 2 || std::string(argv[1]) != "--stdin") throw std::runtime_error("Use --abi or --stdin with one bounded JSON request");
        std::string input; char ch;
        while (std::cin.get(ch)) { if (input.size() >= 65536) throw std::runtime_error("Vision JSON request exceeds 64 KiB"); input += ch; }
        auto request = json::parse(input);
        if (!request.is_object()) throw std::runtime_error("Vision request must be an object");
        for (auto item = request.begin(); item != request.end(); ++item) {
            const auto & key = item.key();
            if (key != "model_id" && key != "model_path" && key != "projector_path" && key != "image_path" && key != "prompt" && key != "max_tokens" && key != "context_size" && key != "threads") throw std::runtime_error("Unsupported vision request field; video and multiple images are unavailable");
        }
        const auto model_id = request.at("model_id").get<std::string>();
        const auto model_path = request.at("model_path").get<std::string>();
        const auto projector_path = request.at("projector_path").get<std::string>();
        const auto image_path = request.at("image_path").get<std::string>();
        const auto prompt = request.at("prompt").get<std::string>();
        for (const auto * value : {&model_id, &model_path, &projector_path, &image_path, &prompt}) if (value->find('\0') != std::string::npos) throw std::runtime_error("NUL is not valid in vision request strings");
        qv::validate_prompt(prompt);
        auto bounded = [&](const char * key, int fallback, int low, int high) {
            if (!request.contains(key)) return uint32_t(fallback);
            if (!request[key].is_number_integer()) throw std::runtime_error("Vision limits must be integers");
            const auto n = request[key].get<int64_t>();
            if (n < low || n > high) throw std::runtime_error("Vision request limit is outside the supported range"); return uint32_t(n);
        };
        const auto context = bounded("context_size", 4096, 1024, 8192), threads = bounded("threads", 4, 1, 16), max_tokens = bounded("max_tokens", 256, 1, 1024);
        std::unique_ptr<quenderin_vision, decltype(&quenderin_vision_free)> state(quenderin_vision_create(), quenderin_vision_free);
        if (!state) throw std::runtime_error("Could not allocate vision worker");
        quenderin_vision_load_options options{1, model_id.c_str(), model_path.c_str(), projector_path.c_str(), context, threads};
        if (quenderin_vision_load(state.get(), &options)) throw std::runtime_error(quenderin_vision_last_error(state.get()));
        quenderin_vision_request generation{1, image_path.c_str(), prompt.c_str(), max_tokens};
        if (quenderin_vision_generate(state.get(), &generation, output, nullptr)) throw std::runtime_error(quenderin_vision_last_error(state.get()));
        emit({{"type", "done"}, {"tokens", quenderin_vision_generated_tokens(state.get())}}); return 0;
    } catch (const nlohmann::json::exception &) {
        emit({{"type", "error"}, {"message", "Invalid vision JSON fields or syntax"}}); return 1;
    } catch (const std::exception & error) {
        // Do not echo prompt, file paths, JSON input or model-produced reasoning.
        emit({{"type", "error"}, {"message", std::string(error.what()).substr(0, 512)}}); return 1;
    } catch (...) { emit({{"type", "error"}, {"message", "Vision worker failed"}}); return 1; }
}
