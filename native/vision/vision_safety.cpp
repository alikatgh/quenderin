#include "vision_safety.h"
#include <algorithm>
#include <cstring>
#include <stdexcept>
#include <cstdlib>
#include <cstddef>
#include <limits>
namespace {
// Header dimensions do not bound a PNG's deflate stream. Bound the real stb
// allocation path too, including realloc's possible old+new temporary peak.
#ifndef QV_STB_ALLOCATION_BUDGET
#define QV_STB_ALLOCATION_BUDGET (256u * 1024u * 1024u)
#endif
constexpr size_t decoder_budget = QV_STB_ALLOCATION_BUDGET;
static_assert(decoder_budget <= 256u * 1024u * 1024u, "Decoder budget cannot exceed 256 MiB");
thread_local size_t decoder_live = 0, decoder_peak = 0;
struct alignas(std::max_align_t) allocation { size_t bytes; };
void * bounded_malloc(size_t bytes) {
    if (bytes > std::numeric_limits<size_t>::max() - sizeof(allocation)) return nullptr;
    const size_t total = bytes + sizeof(allocation);
    if (total > decoder_budget || decoder_live > decoder_budget - total) return nullptr;
    auto * memory = static_cast<allocation *>(std::malloc(total));
    if (!memory) return nullptr;
    memory->bytes = total; decoder_live += total; decoder_peak = std::max(decoder_peak, decoder_live);
    return memory + 1;
}
void bounded_free(void * value) {
    if (!value) return;
    auto * memory = static_cast<allocation *>(value) - 1;
    decoder_live -= memory->bytes; std::free(memory);
}
void * bounded_realloc(void * value, size_t bytes) {
    if (!value) return bounded_malloc(bytes);
    if (bytes > std::numeric_limits<size_t>::max() - sizeof(allocation)) return nullptr;
    const size_t total = bytes + sizeof(allocation);
    if (total > decoder_budget || decoder_live > decoder_budget - total) return nullptr;
    auto * memory = static_cast<allocation *>(value) - 1;
    const size_t previous = memory->bytes;
    auto * updated = static_cast<allocation *>(std::realloc(memory, total));
    if (!updated) return nullptr;
    decoder_peak = std::max(decoder_peak, decoder_live + total);
    decoder_live = decoder_live - previous + total; updated->bytes = total;
    return updated + 1;
}
}
// Only bounded JPEG/PNG still decoding is compiled. No external program/codec.
#define STBI_MALLOC(bytes) bounded_malloc(bytes)
#define STBI_REALLOC_SIZED(value, old_size, new_size) bounded_realloc(value, new_size)
#define STBI_FREE(value) bounded_free(value)
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STBI_MAX_DIMENSIONS 4096
#include "stb/stb_image.h"
namespace qv {
size_t decoder_peak_allocation() { return decoder_peak; }
bool utf8(const std::string & s) {
    for (size_t i = 0; i < s.size();) {
        const auto a = static_cast<unsigned char>(s[i++]);
        if (a < 0x80) continue;
        unsigned n = 0; uint32_t v = 0, minimum = 0;
        if (a >= 0xc2 && a <= 0xdf) { n = 1; v = a & 0x1f; minimum = 0x80; }
        else if (a >= 0xe0 && a <= 0xef) { n = 2; v = a & 0x0f; minimum = 0x800; }
        else if (a >= 0xf0 && a <= 0xf4) { n = 3; v = a & 7; minimum = 0x10000; }
        else return false;
        if (s.size() - i < n) return false;
        while (n--) { auto b = static_cast<unsigned char>(s[i++]); if ((b & 0xc0) != 0x80) return false; v = (v << 6) | (b & 63); }
        if (v < minimum || v > 0x10ffff || (v >= 0xd800 && v <= 0xdfff)) return false;
    }
    return true;
}
void validate_prompt(const std::string & s) {
    if (s.empty() || s.size() > 32768 || !utf8(s) || s.find('\0') != std::string::npos)
        throw std::runtime_error("Use a UTF-8 prompt of 1 to 32768 bytes");
    for (const auto * marker : {"<|", "<__media__>", "<image", "</image", "<video", "<think", "</think", "<tool_call"})
        if (s.find(marker) != std::string::npos) throw std::runtime_error("Prompt contains reserved model markers");
}
std::string render_prompt(const std::string & family, const std::string & marker, const std::string & prompt) {
    validate_prompt(prompt);
    if (family == "minicpm47")
        return "<|im_start|>user\n" + marker + "\n" + prompt + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";
    if (family == "nemotron35vl")
        return "<|im_start|>system\n<|im_end|>\n<|im_start|>user\n" + marker + prompt + "<|im_end|>\n<|im_start|>assistant\n<think></think>";
    throw std::runtime_error("Unsupported vision prompt family");
}
std::string visible_answer(std::string s) {
    // Buffer through completion; no reasoning fragment is emitted before its
    // matching close. An orphan close also discards the preceding reasoning.
    for (;;) {
        auto open = s.find("<think>"); auto close = s.find("</think>");
        if (open == std::string::npos && close == std::string::npos) break;
        if (close != std::string::npos && (open == std::string::npos || close < open)) { s.erase(0, close + 8); continue; }
        close = s.find("</think>", open + 7);
        s.erase(open, close == std::string::npos ? std::string::npos : close + 8 - open);
    }
    auto tool = s.find("<tool_call"); if (tool != std::string::npos) s.erase(tool);
    for (const auto * end : {"<|im_end|>", "<|im_start|>", "<|endoftext|>"}) {
        auto i = s.find(end); if (i != std::string::npos) s.erase(i);
    }
    // Disallow unfinished controls and remove an incomplete final UTF-8 token.
    auto control = s.find("<|"); if (control != std::string::npos) s.erase(control);
    while (!s.empty() && !utf8(s)) s.pop_back();
    auto begin = s.find_first_not_of(" \t\r\n");
    if (begin == std::string::npos) return "";
    return s.substr(begin, s.find_last_not_of(" \t\r\n") - begin + 1);
}
static uint32_t be32(const unsigned char * p) { return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3]; }
image decode_still(const std::vector<unsigned char> & b) {
    if (decoder_live) throw std::runtime_error("Image decoder still owns allocations from a previous request");
    decoder_peak = 0;
    if (b.empty() || b.size() > max_image_bytes) throw std::runtime_error("Image must be at most 8 MiB");
    const unsigned char png[] = {137,80,78,71,13,10,26,10};
    const bool is_png = b.size() >= 33 && !std::memcmp(b.data(), png, 8);
    const bool is_jpg = b.size() >= 4 && b[0] == 255 && b[1] == 216 && b[2] == 255;
    if (!is_png && !is_jpg) throw std::runtime_error("Only one JPEG or PNG still image is supported; video and animation are unavailable");
    if (is_jpg) {
        // Walk segment lengths rather than searching EXIF/thumbnail payloads.
        // The first actual end marker must end the file: MPO/motion-photo
        // trailers and concatenated images must not be silently ignored.
        size_t i = 2; bool ended = false;
        while (i < b.size()) {
            if (b[i++] != 255) throw std::runtime_error("Invalid JPEG marker");
            while (i < b.size() && b[i] == 255) ++i;
            if (i == b.size()) break;
            const auto marker = b[i++];
            if (marker == 217) { ended = i == b.size(); break; }
            if (marker == 216 || marker == 0) throw std::runtime_error("Multiple images or invalid JPEG marker");
            if (marker == 1 || (marker >= 208 && marker <= 215)) continue;
            if (b.size() - i < 2) throw std::runtime_error("Truncated JPEG segment");
            const size_t count = size_t(b[i]) * 256 + b[i + 1];
            if (count < 2 || count > b.size() - i) throw std::runtime_error("Invalid JPEG segment length");
            i += count;
            if (marker == 218) {
                while (i + 1 < b.size()) {
                    if (b[i] != 255) { ++i; continue; }
                    const auto next = b[i + 1];
                    if (next == 0 || (next >= 208 && next <= 215)) { i += 2; continue; }
                    break;
                }
            }
        }
        if (!ended) throw std::runtime_error("JPEG must contain exactly one complete still image; video and multiple images are unavailable");
    }
    if (is_png) {
        bool ihdr = false, iend = false;
        for (size_t off = 8; off < b.size();) {
            if (b.size() - off < 12) throw std::runtime_error("Truncated PNG metadata");
            uint32_t n = be32(b.data() + off);
            if (n > b.size() - off - 12) throw std::runtime_error("Invalid PNG chunk bounds");
            const auto * type = b.data() + off + 4;
            if (!std::memcmp(type, "acTL", 4) || !std::memcmp(type, "fcTL", 4) || !std::memcmp(type, "fdAT", 4)) throw std::runtime_error("Animated PNG is unavailable; use a still image");
            if (off == 8) { if (n != 13 || std::memcmp(type, "IHDR", 4)) throw std::runtime_error("Missing PNG dimensions"); ihdr = true; }
            if (!std::memcmp(type, "IEND", 4)) { if (n || off + 12 != b.size()) throw std::runtime_error("Invalid PNG ending"); iend = true; }
            off += size_t(n) + 12;
        }
        if (!ihdr || !iend) throw std::runtime_error("Incomplete PNG metadata");
    }
    int x = 0, y = 0, channels = 0;
    // Metadata is validated before the decoder is allowed to allocate pixels.
    if (!stbi_info_from_memory(b.data(), int(b.size()), &x, &y, &channels) || x <= 0 || y <= 0 || x > int(max_side) || y > int(max_side) || uint64_t(x) * y > max_pixels)
        throw std::runtime_error("Invalid image metadata or image exceeds 4096 sides / 16 million pixels");
    unsigned char * pixels = stbi_load_from_memory(b.data(), int(b.size()), &x, &y, &channels, 3);
    if (!pixels) throw std::runtime_error("Image decoding failed");
    image result{uint32_t(x), uint32_t(y), {}};
    try { result.rgb.assign(pixels, pixels + size_t(x) * y * 3); } catch (...) { stbi_image_free(pixels); throw; }
    stbi_image_free(pixels);
    return result;
}
}
