#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>
namespace qv {
constexpr size_t max_image_bytes = 8 * 1024 * 1024;
constexpr uint32_t max_side = 4096, max_pixels = 16000000;
bool utf8(const std::string & text);
void validate_prompt(const std::string & prompt);
std::string render_prompt(const std::string & family, const std::string & marker, const std::string & prompt);
std::string visible_answer(std::string text);
struct image { uint32_t width, height; std::vector<unsigned char> rgb; };
image decode_still(const std::vector<unsigned char> & bytes);
size_t decoder_peak_allocation();
}
