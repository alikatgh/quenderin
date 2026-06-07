// Proof that QuenderinKit's LlamaEngine C-API sequence actually links and runs against
// real llama.cpp (Metal). Mirrors LlamaEngine.swift's load → tokenize → decode → sample →
// detokenize, standalone, so it can be verified WITHOUT the full Xcode app target.
//
// Build + run via `apple/verify-llama-link.sh` (which builds llama.cpp + a tiny model).
// VERIFIED 2026-06-07 (macOS, Xcode 16.2): coherent output, Metal GPU, ~177 tok/s decode
// for a 0.5B Q4 model on an M-series Mac.
//
//   usage: llama-smoketest <model.gguf> [prompt] [maxTokens]

import llama
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: llama-smoketest <model.gguf> [prompt] [maxTokens]"); exit(2) }
let modelPath = args[1]
let userText = args.count >= 3 ? args[2] : "Write three sentences about why the sky is blue."
let maxTokens = args.count >= 4 ? (Int(args[3]) ?? 96) : 96
// Qwen/ChatML template; harmless for other models in this smoke test.
let prompt = "<|im_start|>user\n\(userText)<|im_end|>\n<|im_start|>assistant\n"

llama_backend_init(); defer { llama_backend_free() }

// GPU layers: default all-on-Metal; set QUENDERIN_NGL=0 to force CPU (the iOS *simulator*
// has a broken Metal compute path that yields garbage — use CPU there; real devices use Metal).
let ngl = Int32(ProcessInfo.processInfo.environment["QUENDERIN_NGL"] ?? "99") ?? 99
var mp = llama_model_default_params(); mp.n_gpu_layers = ngl
guard let model = llama_model_load_from_file(modelPath, mp) else { print("FAIL: model load"); exit(1) }
defer { llama_model_free(model) }

var cp = llama_context_default_params(); cp.n_ctx = 2048
guard let ctx = llama_init_from_model(model, cp) else { print("FAIL: context"); exit(1) }
defer { llama_free(ctx) }
let vocab = llama_model_get_vocab(model)

var tokens = [llama_token](repeating: 0, count: 1024)
let n = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens, 1024, true, true)
guard n > 0 else { print("FAIL: tokenize (\(n))"); exit(1) }
tokens = Array(tokens.prefix(Int(n)))

let smpl = llama_sampler_chain_init(llama_sampler_chain_default_params()); defer { llama_sampler_free(smpl) }
llama_sampler_chain_add(smpl, llama_sampler_init_greedy())

func decode(_ t: inout [llama_token]) -> Bool {
    t.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress, Int32($0.count))) == 0 }
}
func piece(_ tok: llama_token) -> String {
    var b = [CChar](repeating: 0, count: 256)
    let c = llama_token_to_piece(vocab, tok, &b, 256, 0, true)
    return c > 0 ? String(decoding: b.prefix(Int(c)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
}

let t0 = Date(); guard decode(&tokens) else { print("FAIL: prompt decode"); exit(1) }
let prefill = Date().timeIntervalSince(t0)

var out = "", gen = 0; let t1 = Date()
while gen < maxTokens {
    let tok = llama_sampler_sample(smpl, ctx, -1)
    if llama_vocab_is_eog(vocab, tok) { break }
    out += piece(tok); gen += 1
    var one = [tok]; if !decode(&one) { break }
}
let dt = Date().timeIntervalSince(t1)

print("ANSWER: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
print(String(format: "REAL: prefill %d tok in %.0fms (%.0f tok/s) · decode %d tok in %.2fs = %.1f tok/s",
             n, prefill * 1000, Double(n) / prefill, gen, dt, Double(gen) / max(dt, 1e-6)))
