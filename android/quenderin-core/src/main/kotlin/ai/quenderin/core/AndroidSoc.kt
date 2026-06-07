package ai.quenderin.core

import kotlin.math.roundToInt

/**
 * Android SoC families relevant to on-device LLM inference. `inferenceScore` is a
 * RELATIVE decode-throughput multiplier on the SAME scale as iOS `AppleChip`
 * (A18 Pro ≡ 1.0), so cross-platform comparisons hold.
 *
 * CALIBRATED FROM MEASURED DATA (see apple/REALITY.md, docs/research/on-device-llm.md):
 * anchored to Kirin 9000 (10.2 tok/s for 1.5B, stock llama.cpp) and Dimensity 9300
 * (~1.9× decode vs Kirin 9000E). Decode is memory-bandwidth bound, so GPU/NPU mostly
 * help prefill, not these numbers. Snapdragon 8 Elite / Dimensity 9400 / Tensor figures
 * are interpolated — replace with real device benchmarks (the on-device cliff).
 */
enum class AndroidSoc(val displayName: String, val inferenceScore: Double) {
    SNAPDRAGON_8_GEN_1("Snapdragon 8 Gen 1", 0.62),
    SNAPDRAGON_8_GEN_2("Snapdragon 8 Gen 2", 0.74),
    SNAPDRAGON_8_GEN_3("Snapdragon 8 Gen 3", 0.85),
    SNAPDRAGON_8_ELITE("Snapdragon 8 Elite", 1.00),
    DIMENSITY_9200("Dimensity 9200", 0.74),
    DIMENSITY_9300("Dimensity 9300", 0.88),
    DIMENSITY_9400("Dimensity 9400", 1.00),
    TENSOR_G2("Tensor G2", 0.55),
    TENSOR_G3("Tensor G3", 0.60),
    TENSOR_G4("Tensor G4", 0.66),
    EXYNOS_2400("Exynos 2400", 0.80),
    MIDRANGE("Mid-range SoC", 0.50),
    UNKNOWN("Android SoC", 0.45);

    companion object {
        /**
         * Resolve `Build.SOC_MODEL` (API 31+) or a hardware string to a chip. Unknown
         * strings fall back to [UNKNOWN] (a conservative score). Case-insensitive.
         */
        fun fromSocModel(socModel: String?): AndroidSoc {
            val s = socModel?.lowercase()?.trim() ?: return UNKNOWN
            return when {
                // Qualcomm Snapdragon (SoC model codes)
                s.contains("sm8750") -> SNAPDRAGON_8_ELITE
                s.contains("sm8650") -> SNAPDRAGON_8_GEN_3
                s.contains("sm8550") -> SNAPDRAGON_8_GEN_2
                s.contains("sm8475") || s.contains("sm8450") -> SNAPDRAGON_8_GEN_1
                // MediaTek Dimensity
                s.contains("mt6991") -> DIMENSITY_9400
                s.contains("mt6989") -> DIMENSITY_9300
                s.contains("mt6985") -> DIMENSITY_9200
                // Google Tensor
                s.contains("zumapro") -> TENSOR_G4
                s.contains("zuma") -> TENSOR_G3
                s.contains("gs201") -> TENSOR_G2
                // Samsung Exynos
                s.contains("s5e9945") || s.contains("exynos 2400") -> EXYNOS_2400
                // Human-readable fallbacks
                s.contains("8 elite") -> SNAPDRAGON_8_ELITE
                s.contains("8 gen 3") -> SNAPDRAGON_8_GEN_3
                s.contains("8 gen 2") -> SNAPDRAGON_8_GEN_2
                s.contains("9400") -> DIMENSITY_9400
                s.contains("9300") -> DIMENSITY_9300
                s.contains("snapdragon 7") || s.contains("dimensity 8") -> MIDRANGE
                else -> UNKNOWN
            }
        }

        /**
         * Memory a native LLM can realistically use, as a fraction of total RAM.
         *
         * KEY ANDROID DIFFERENCE vs iOS: llama.cpp allocates on the NATIVE heap via JNI,
         * which is NOT bounded by the small Dalvik/ART per-app heap cap — only by total
         * RAM and the kernel low-memory-killer. A foreground app can use a large share,
         * so budgets are MORE generous than iOS jetsam. We still leave headroom so the LMK
         * doesn't reap us under multitasking. Android flagships also reach 12–16 GB, which
         * unlocks 7B-class models that no 8 GB iPhone can hold.
         */
        fun nativeMemoryBudgetGB(totalRamGb: Double): Double {
            val fraction = when {
                totalRamGb < 4.5 -> 0.55   // 4 GB → ~2.2
                totalRamGb < 6.5 -> 0.73   // 6 GB → ~4.4
                totalRamGb < 8.5 -> 0.74   // 8 GB → ~5.9 (≈ iOS 8 GB)
                totalRamGb < 12.5 -> 0.75  // 12 GB → ~9.0
                else -> 0.75               // 16 GB → ~12.0 (tiers no iPhone has)
            }
            return (totalRamGb * fraction * 10).roundToInt() / 10.0
        }
    }
}
