#pragma once
// Model-free host fixture API. The implementation under test is the real llama_generate.h.
#include <cstdint>
#include <cstddef>
using llama_token = int32_t;
using llama_pos = int32_t;
inline constexpr llama_token LLAMA_TOKEN_NULL = -1;
struct llama_context {
    uint32_t n_ctx = 2048, n_batch = 512;
    int decode_calls = 0, fail_at = -1, failure_code = -3, clears = 0;
};
struct llama_vocab {};
struct llama_sampler { int sampled = 0, goal = 40; };
struct llama_batch { llama_token* tokens; int32_t n_tokens; };
using llama_memory_t = llama_context*;
uint32_t llama_n_ctx(llama_context*);
uint32_t llama_n_batch(llama_context*);
llama_batch llama_batch_get_one(llama_token*, int32_t);
int llama_decode(llama_context*, llama_batch);
llama_memory_t llama_get_memory(llama_context*);
void llama_memory_clear(llama_memory_t, bool);
bool llama_memory_seq_rm(llama_memory_t, int, llama_pos, llama_pos);
void llama_memory_seq_add(llama_memory_t, int, llama_pos, llama_pos, llama_pos);
void llama_synchronize(llama_context*);
void llama_perf_context_reset(llama_context*);
llama_token llama_vocab_bos(const llama_vocab*);
llama_token llama_vocab_eos(const llama_vocab*);
bool llama_vocab_is_eog(const llama_vocab*, llama_token);
llama_token llama_sampler_sample(llama_sampler*, llama_context*, int);
int llama_token_to_piece(const llama_vocab*, llama_token, char*, int32_t, int, bool);
void llama_set_n_threads(llama_context*, int, int);
