#pragma once
#include <algorithm>
#include <cstddef>

namespace quenderin {
// Twin of Swift PromptBatchDecoder. Injectable native call keeps the actual loop testable
// without a multi-GB model or GPU. A cancelled prefill invalidates the caller's KV mirror.
inline constexpr size_t kMaximumPromptBatchTokens = 512;
struct PromptBatchResult { int code; bool cancelled; };

template <typename Cancelled, typename Decode>
PromptBatchResult decodePromptBatches(size_t tokenCount, size_t batchSize,
                                     Cancelled isCancelled, Decode decodeBatch) {
    const size_t limit = std::max<size_t>(1, std::min(batchSize, kMaximumPromptBatchTokens));
    size_t start = 0;
    while (start < tokenCount) {
        if (isCancelled()) return {0, true};
        const size_t end = start + std::min(limit, tokenCount - start);
        const int code = decodeBatch(start, end);
        if (isCancelled()) return {0, true};
        if (code != 0) return {code, false};
        start = end;
    }
    return {0, isCancelled()};
}
} // namespace quenderin
