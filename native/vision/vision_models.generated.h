#pragma once
#include <cstdint>
struct qv_artifact { const char * filename; uint64_t bytes; const char * sha256; };
struct qv_model_descriptor { const char * id; const char * family; qv_artifact model; qv_artifact projector; };
static const qv_model_descriptor qv_models[] = {
    {"minicpm-v47-1b", "minicpm47", {"MiniCPM-V-4_7-1B-Q4_K_M.gguf", 672003680ULL, "588c6c94c82f756b86dba35c42ed9ba9ec187d65824eb52f039c347df563e63d"}, {"mmproj-model-f16.gguf", 1110117984ULL, "fb9cc047a3cdad5317fd8433a4aeda2d22f00f02ca4bd93b34ad84165b25a900"}},
    {"minicpm-v47-35b-a3b", "minicpm47", {"MiniCPM-V-4_7-35B-A3B-Q4_K_M.gguf", 21166255008ULL, "bf3d1c67f7843193e4483aebd26c5dea6b6d1f6a06ffa03c2387a6f3cc6d7df5"}, {"mmproj-model-f16.gguf", 1119575840ULL, "bff3b688e14c300eca273092c37c50a0ddfcc2054e079af1a0480edeed5d20f1"}},
    {"nemotron-3.5-super-vl-120b-a12b", "nemotron35vl", {"NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-Q4_0.gguf", 71803752384ULL, "1d51968bb20cd34760fb75a1e4a03b6dea247bcb4bf5d6e27b0964a558d7f922"}, {"mmproj-NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-BF16.gguf", 1733696768ULL, "1ce431097d6579f17097ec92282ef8007838ec24dfda60c27a5bd34bb5642c43"}},
};
