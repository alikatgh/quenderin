#pragma once
#include <string>
#include <utility>
#include <vector>

namespace quenderin {
inline std::string escapeBeamText(std::string text) {
    size_t pos = 0;
    while ((pos = text.find("<|", pos)) != std::string::npos) { text.insert(pos + 1, " "); pos += 3; }
    return text;
}
// Exact official minimal-effort text template. Native history is final-only;
// choose the publisher's allow_missing_thinking=true policy explicitly.
inline std::string beamChatPrompt(const std::vector<std::pair<std::string, std::string>> & messages) {
    std::string instructions;
    bool conversation = false;
    for (const auto & m : messages) {
        if (m.first == "system" || m.first == "developer") {
            if (conversation) return {};
            if (!m.second.empty()) { if (!instructions.empty()) instructions += "\n\n"; instructions += m.second; }
        } else if (m.first == "user" || m.first == "assistant") conversation = true;
        else return {}; // tools require their own explicit XML workflow
    }
    std::string out = "<|start|>system<|message|>You are Beam, an AI assistant trained by Reflection.\n\nReasoning effort: 8"
        "\n\n# Valid channels: analysis, final. Channel must be included for every message.<|end|>";
    if (!instructions.empty()) out += "<|start|>developer<|message|># Instructions\n\n" + escapeBeamText(instructions) + "<|end|>";
    for (const auto & m : messages) {
        if (m.first == "user") out += "<|start|>user<|message|>" + escapeBeamText(m.second) + "<|end|>";
        else if (m.first == "assistant") out += "<|start|>assistant<|channel|>analysis<|message|><|end|>"
            "<|start|>assistant<|channel|>final<|message|>" + escapeBeamText(m.second) + "<|return|>";
    }
    return out + "<|start|>assistant";
}
} // namespace quenderin
