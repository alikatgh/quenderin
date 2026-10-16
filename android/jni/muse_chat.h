#pragma once

#include <string>
#include <utility>
#include <vector>

namespace quenderin {

// Text-only subset of the pinned upstream Muse template. Treat message bodies as
// data: a pasted protocol token must not create another role or multimodal input.
inline std::string escapeMuseText(std::string text) {
    for (const auto &token : {std::string("<|"), std::string("<image>"),
                              std::string("<video>"), std::string("<audio>")}) {
        size_t pos = 0;
        while ((pos = text.find(token, pos)) != std::string::npos) {
            text.insert(pos + 1, " ");
            pos += token.size() + 1;
        }
    }
    return text;
}

inline std::string museChatPrompt(const std::vector<std::pair<std::string, std::string>> &messages) {
    std::string system;
    for (const auto &message : messages) {
        if (message.first == "system") {
            if (!system.empty()) system += "\n\n";
            system += message.second;
        } else if (message.first != "user" && message.first != "assistant") {
            return {}; // Tool messages require a separate, explicit adapter.
        }
    }
    if (!system.empty()) system += "\n\n";
    system += "Reasoning strength: 16.\nUse to=self for private reasoning and to=user for the final answer.";
    std::string prompt = "<|begin_of_text|><|start|>system<|message|>" + escapeMuseText(system) + "<|eot|>";
    for (const auto &message : messages) {
        if (message.first == "system") continue;
        prompt += "<|start|>";
        prompt += message.first == "assistant" ? "assistant to=user" : "user";
        prompt += "<|message|>" + escapeMuseText(message.second) + "<|eot|>";
    }
    return prompt + "<|start|>assistant";
}

} // namespace quenderin
