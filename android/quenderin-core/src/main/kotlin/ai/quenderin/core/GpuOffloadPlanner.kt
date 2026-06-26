package ai.quenderin.core

/**
 * Decides how many model layers to offload to the GPU (llama.cpp `n_gpu_layers`) on Android.
 *
 * WHY THIS IS A DECISION — and not just `999` like iOS Metal:
 *  - **Android has no single GPU API.** llama.cpp reaches the GPU through Vulkan, and driver quality
 *    is heterogeneous: Qualcomm **Adreno** (Snapdragon) is the proven, well-tested llama.cpp Vulkan
 *    target, while **Mali** (Dimensity/Tensor) and **Xclipse** (Exynos) historically range from
 *    slower-than-CPU to outright crashing on the compute shaders llama.cpp emits.
 *  - **On mobile, DECODE is memory-bandwidth bound.** The CPU and GPU share the same RAM bus, so
 *    offloading the matmuls doesn't speed steady token generation much — it mainly speeds **prefill**
 *    (the one-shot prompt pass), i.e. long-prompt time-to-first-token. (See [AndroidSoc]: "GPU/NPU
 *    mostly help prefill, not these numbers.") Mobile GPUs use *unified* memory, so there's no
 *    separate VRAM budget — offload is all-or-nothing, not a layer-count fit problem.
 *
 * So the policy is **safe by default**: offload everything only on a known-good GPU family; otherwise
 * stay on CPU (correct + stable) until that device is actually benchmarked on real hardware. A
 * [forceGpu] override exists precisely so you can A/B an untrusted GPU on a physical device.
 *
 * Pure + testable. Twin note: iOS `LlamaEngine` offloads all layers unconditionally because Metal is a
 * single, uniform, Apple-controlled driver — the heterogeneity that forces this decision is Android-only.
 */
object GpuOffloadPlanner {
    /** llama.cpp sentinel for "offload every layer". Mobile GPUs share system RAM (unified memory),
     *  so there's no VRAM ceiling to fit against — it's all layers or none. */
    const val ALL_LAYERS = 999
    const val CPU_ONLY = 0

    /** GPU families grouped by their llama.cpp Vulkan maturity (the thing that actually decides safety). */
    enum class GpuClass { ADRENO, MALI, XCLIPSE, UNKNOWN }

    fun gpuClass(soc: AndroidSoc): GpuClass = when (soc) {
        AndroidSoc.SNAPDRAGON_8_GEN_1, AndroidSoc.SNAPDRAGON_8_GEN_2,
        AndroidSoc.SNAPDRAGON_8_GEN_3, AndroidSoc.SNAPDRAGON_8_ELITE -> GpuClass.ADRENO
        AndroidSoc.DIMENSITY_9200, AndroidSoc.DIMENSITY_9300, AndroidSoc.DIMENSITY_9400,
        AndroidSoc.TENSOR_G2, AndroidSoc.TENSOR_G3, AndroidSoc.TENSOR_G4 -> GpuClass.MALI
        AndroidSoc.EXYNOS_2400 -> GpuClass.XCLIPSE
        AndroidSoc.MIDRANGE, AndroidSoc.UNKNOWN -> GpuClass.UNKNOWN
    }

    /**
     * The `n_gpu_layers` to pass to `nativeLoad`.
     *
     * @param soc resolved from `Build.SOC_MODEL` ([AndroidSoc.fromSocModel]).
     * @param vulkanAvailable whether `libquenderin_llama.so` was built with the Vulkan backend
     *   (`-DGGML_VULKAN=ON`). A CPU-only build has no GPU to offload to → always [CPU_ONLY].
     * @param forceGpu opt-in override to offload on an untrusted GPU family — for benchmarking a real
     *   device. Ignored when [vulkanAvailable] is false (there's still no backend).
     * @return [ALL_LAYERS] to offload everything, or [CPU_ONLY] to run on CPU.
     */
    fun recommend(soc: AndroidSoc, vulkanAvailable: Boolean, forceGpu: Boolean = false): Int {
        if (!vulkanAvailable) return CPU_ONLY               // no Vulkan backend compiled in
        if (forceGpu) return ALL_LAYERS                     // explicit benchmark / override
        return when (gpuClass(soc)) {
            GpuClass.ADRENO -> ALL_LAYERS                   // Qualcomm Adreno: the proven Vulkan target
            else -> CPU_ONLY                                // Mali / Xclipse / unknown: CPU until benchmarked
        }
    }

    /** A one-line, honest explanation for logs / a settings row — why GPU is or isn't in use. */
    fun rationale(soc: AndroidSoc, vulkanAvailable: Boolean, forceGpu: Boolean = false): String = when {
        !vulkanAvailable -> "CPU (this build has no Vulkan backend)"
        forceGpu -> "GPU: all layers (forced override — benchmarking ${soc.displayName})"
        gpuClass(soc) == GpuClass.ADRENO -> "GPU: all layers via Vulkan (${soc.displayName}, Adreno — proven)"
        else -> "CPU (${soc.displayName} GPU not yet validated for Vulkan offload; mainly affects prefill anyway)"
    }
}
