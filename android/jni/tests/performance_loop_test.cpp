// Host only: no library/model/device. Compile with -Itests/performance-stub -Ijni.
#include "llama_generate.h"
#include <cassert>
#include <iostream>
#include <thread>

uint32_t llama_n_ctx(llama_context* c) { return c->n_ctx; }
uint32_t llama_n_batch(llama_context* c) { return c->n_batch; }
llama_batch llama_batch_get_one(llama_token* tokens, int32_t count) { return {tokens, count}; }
int llama_decode(llama_context* c, llama_batch) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
    return ++c->decode_calls == c->fail_at ? c->failure_code : 0;
}
llama_memory_t llama_get_memory(llama_context* c) { return c; }
void llama_memory_clear(llama_memory_t c, bool) { ++c->clears; }
bool llama_memory_seq_rm(llama_memory_t, int, llama_pos, llama_pos) { return true; }
void llama_memory_seq_add(llama_memory_t, int, llama_pos, llama_pos, llama_pos) {}
void llama_synchronize(llama_context*) {}
void llama_perf_context_reset(llama_context*) {}
llama_token llama_vocab_bos(const llama_vocab*) { return 0; }
llama_token llama_vocab_eos(const llama_vocab*) { return 0; }
bool llama_vocab_is_eog(const llama_vocab*, llama_token token) { return token == 0; }
llama_token llama_sampler_sample(llama_sampler* sampler, llama_context*, int) {
    return ++sampler->sampled > sampler->goal ? 0 : sampler->sampled;
}
int llama_token_to_piece(const llama_vocab*, llama_token token, char* buffer, int32_t size, int, bool) {
    if (size < 1) return -1;
    // Two actual model tokens become ONE valid Cyrillic character/UI piece.
    buffer[0] = token % 2 == 1 ? char(0xD0) : char(0xB0);
    return 1;
}
void llama_set_n_threads(llama_context*, int, int) {}

int main() {
    llama_vocab vocab;
    {
        llama_context ctx; llama_sampler sampler; std::vector<llama_token> cached;
        quenderin::GenerationPerformance report; bool failed = true, cap = true; int pieces = 0;
        auto output = quenderin::generateWithKVReuse(&ctx, &vocab, &sampler, std::vector<llama_token>(128, 7), 64,
            cached, [&](const std::string&) { ++pieces; return true; }, [] { return false; }, &failed,
            [] { return 4; }, &cap, &report);
        assert(!failed && !cap && report.status == 0);
        assert(report.promptTokens == 128 && report.prefillTokens == 128 && report.decodedTokens == 40);
        assert(pieces == 20 && output.size() == 40 && cached.size() == 168);
        assert(report.prefillMs > 0 && report.decodeMs > 0 && report.firstTokenMs >= report.prefillMs && report.maxGapMs > 0);
        assert(report.cacheMode == 0);
        std::vector<llama_token> next = cached; next.push_back(8); sampler.sampled = 0;
        quenderin::generateWithKVReuse(&ctx, &vocab, &sampler, next, 64, cached,
            [](const std::string&) { return true; }, [] { return false; }, &failed, [] { return 0; }, &cap, &report);
        assert(report.status == 0 && report.cacheMode == 1 && report.prefillTokens == 1 && report.promptTokens == 169);
    }
    for (int code : {-3, 1}) {
        llama_context ctx; ctx.fail_at = 5; ctx.failure_code = code;
        llama_sampler sampler; std::vector<llama_token> cached; bool failed = false;
        quenderin::GenerationPerformance report;
        auto output = quenderin::generateWithKVReuse(&ctx, &vocab, &sampler, std::vector<llama_token>(128, 7), 64,
            cached, [](const std::string&) { return true; }, [] { return false; }, &failed, [] { return 0; }, nullptr, &report);
        assert(!output.empty() && !failed); // Native's existing usable partial-text behavior is preserved.
        assert(report.status == (code < 0 ? 2 : 3)); // Neither partial can become successful evidence.
    }
    {
        llama_context ctx; ctx.fail_at = 1; llama_sampler sampler; std::vector<llama_token> cached{1};
        bool failed = false; quenderin::GenerationPerformance report;
        auto output = quenderin::generateWithKVReuse(&ctx, &vocab, &sampler, std::vector<llama_token>(128, 7), 64,
            cached, [](const std::string&) { return true; }, [] { return false; }, &failed, [] { return 0; }, nullptr, &report);
        assert(failed && output.empty() && cached.empty() && report.status == 2);
    }
    {
        llama_context ctx; llama_sampler sampler; std::vector<llama_token> cached;
        quenderin::GenerationPerformance report;
        quenderin::generateWithKVReuse(&ctx, &vocab, &sampler, std::vector<llama_token>(128, 7), 64,
            cached, [](const std::string&) { return true; }, [&] { return ctx.decode_calls >= 5; }, nullptr, [] { return 0; }, nullptr, &report);
        assert(report.status == 1 && report.decodedTokens > 0 && report.decodedTokens < 40);
        sampler.sampled = 0; cached.clear();
        quenderin::generateWithKVReuse(&ctx, &vocab, &sampler, std::vector<llama_token>(128, 7), 64,
            cached, [](const std::string&) { return true; }, [] { return true; }, nullptr, [] { return 0; }, nullptr, &report);
        assert(report.status == 1 && report.decodedTokens == 0 && cached.empty());
    }
    {
        llama_context ctx; llama_sampler sampler; std::vector<llama_token> cached; quenderin::GenerationPerformance report;
        quenderin::generateWithKVReuse(&ctx, &vocab, &sampler, std::vector<llama_token>(128, 7), 64,
            cached, [](const std::string&) { return false; }, [] { return false; }, nullptr, [] { return 0; }, nullptr, &report);
        assert(report.status == 4);
        sampler.sampled = 0; cached.clear();
        quenderin::generateWithKVReuse(&ctx, &vocab, &sampler, std::vector<llama_token>(4096, 7), 64,
            cached, [](const std::string&) { return true; }, [] { return false; }, nullptr, [] { return 0; }, nullptr, &report);
        assert(report.status == 5 && report.promptTokens < 4096);
    }
    std::cout << "PASS: actual native loop numeric metrics, token/piece distinction and failed/cancelled/truncated outcomes\n";
}
