// Model-free regression checks for the actual loop used by llama_generate.h.
// clang++ -std=c++17 android/tools/prompt-batch-test.cpp -o /tmp/prompt-batch-test && /tmp/prompt-batch-test
#include "../jni/prompt_batch_decoder.h"
#include <cassert>
#include <cstdio>
#include <utility>
#include <vector>

int main() {
    using quenderin::decodePromptBatches;
    int calls = 0;
    auto before = decodePromptBatches(1200, 512, [] { return true; },
        [&](size_t, size_t) { ++calls; return 0; });
    assert(before.cancelled && calls == 0);

    bool stopped = false;
    std::vector<std::pair<size_t, size_t>> ranges;
    auto during = decodePromptBatches(1200, 2048, [&] { return stopped; },
        [&](size_t a, size_t b) { ranges.emplace_back(a, b); stopped = true; return 0; });
    assert(during.cancelled && ranges.size() == 1 && ranges[0].second == 512);

    stopped = false;
    auto final = decodePromptBatches(1, 512, [&] { return stopped; },
        [&](size_t, size_t) { stopped = true; return 0; });
    assert(final.cancelled);

    calls = 0;
    auto failure = decodePromptBatches(1200, 512, [] { return false; },
        [&](size_t, size_t) { ++calls; return -7; });
    assert(!failure.cancelled && failure.code == -7 && calls == 1);

    ranges.clear();
    auto success = decodePromptBatches(601, 256, [] { return false; },
        [&](size_t a, size_t b) { ranges.emplace_back(a, b); return 0; });
    const std::vector<std::pair<size_t, size_t>> expected{{0, 256}, {256, 512}, {512, 601}};
    assert(!success.cancelled && success.code == 0 && ranges == expected);

    calls = 0;
    auto empty = decodePromptBatches(0, 0, [] { return false; },
        [&](size_t, size_t) { ++calls; return 0; });
    assert(!empty.cancelled && empty.code == 0 && calls == 0);
    auto zero = decodePromptBatches(2, 0, [] { return false; },
        [&](size_t, size_t) { ++calls; return 0; });
    assert(!zero.cancelled && zero.code == 0 && calls == 2);
    std::puts("PASS: prompt cancellation, final-batch Stop, native errors, batch bounds, empty prompt");
}
