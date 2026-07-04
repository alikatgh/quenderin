package ai.quenderin.core

/**
 * The portable "brain" of Quenderin on Android, in pure Kotlin (no Android deps),
 * so it compiles and unit-tests on the JVM and ships unchanged in the app module.
 *
 * Mirrors `apple/QuenderinKit` (Swift) and `src/constants.ts` (desktop). The three
 * platforms must agree on the catalog and the recommendation — keep them in sync.
 */

data class QuantizationInfo(
    val id: String,
    val bitsPerWeight: Double,
    val quality: String,
    val recommended: Boolean,
)

object Quantization {
    val all: List<QuantizationInfo> = listOf(
        QuantizationInfo("Q2_K", 2.625, "Low", false),
        QuantizationInfo("Q3_K_M", 3.5, "Fair", false),
        QuantizationInfo("Q4_K_M", 4.5, "Good", true),
        QuantizationInfo("Q5_K_M", 5.5, "High", false),
        QuantizationInfo("Q6_K", 6.5, "Very High", false),
        QuantizationInfo("Q8_0", 8.0, "Excellent", false),
    )

    fun info(id: String): QuantizationInfo? = all.firstOrNull { it.id == id }
}

/** A downloadable model "module" — a GGUF the device pulls down to become useful. */
data class ModelEntry(
    val id: String,
    val label: String,
    val filename: String,
    /** Estimated peak RAM footprint (GB), incl. context/KV-cache overhead. */
    val ramGB: Double,
    val sizeLabel: String,
    val paramsBillions: Double,
    val quantization: String,
    val url: String,
    /** Expected GGUF SHA-256 (lowercase hex) for post-download integrity checks; null = magic-only. */
    val sha256: String? = null,
)

/** Multi-family catalog, sorted best → smallest. Mirrors MODEL_CATALOG. */
object ModelCatalog {
    val models: List<ModelEntry> = listOf(
        ModelEntry("qwen3-14b", "Qwen3 14B (Best Quality)", "qwen3-14b.Q4_K_M.gguf", 11.0, "9.0 GB download", 14.0, "Q4_K_M", "https://huggingface.co/Qwen/Qwen3-14B-GGUF/resolve/main/Qwen3-14B-Q4_K_M.gguf?download=true", "500a8806e85ee9c83f3ae08420295592451379b4f8cf2d0f41c15dffeb6b81f0"),
        ModelEntry("gemma4-12b", "Gemma 4 12B (Multilingual)", "gemma-4-12b-it.Q4_K_M.gguf", 9.0, "7.4 GB download", 12.0, "Q4_K_M", "https://huggingface.co/ggml-org/gemma-4-12B-it-GGUF/resolve/main/gemma-4-12B-it-Q4_K_M.gguf?download=true", "1278394b693672ac2799eadc9a83fd98259a6a88a40acfb1dcaa6c6fc895a606"),
        ModelEntry("qwen25-coder-7b", "Qwen2.5 Coder 7B (Coding)", "qwen2.5-coder-7b-instruct.Q4_K_M.gguf", 6.5, "4.7 GB download", 7.0, "Q4_K_M", "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf?download=true", "509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c"),
        ModelEntry("deepseek-r1-7b", "DeepSeek-R1 7B (Reasoning)", "deepseek-r1-distill-qwen-7b.Q4_K_M.gguf", 6.5, "4.7 GB download", 7.0, "Q4_K_M", "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf?download=true", "731ece8d06dc7eda6f6572997feb9ee1258db0784827e642909d9b565641937b"),
        ModelEntry("llama3-8b", "Llama 3 8B (Best Quality)", "llama-3-instruct-8b.Q4_K_M.gguf", 6.75, "4.7 GB download", 8.0, "Q4_K_M", "https://huggingface.co/lmstudio-community/Meta-Llama-3-8B-Instruct-GGUF/resolve/main/Meta-Llama-3-8B-Instruct-Q4_K_M.gguf?download=true", "ab9e4eec7e80892fd78f74d9a15d0299f1e22121cea44efd68a7a02a3fe9a1da"),
        ModelEntry("mistral-7b", "Mistral 7B (All-Rounder)", "mistral-7b-instruct-v0.3.Q4_K_M.gguf", 6.0, "4.1 GB download", 7.0, "Q4_K_M", "https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/Mistral-7B-Instruct-v0.3-Q4_K_M.gguf?download=true", "1270d22c0fbb3d092fb725d4d96c457b7b687a5f5a715abe1e818da303e562b6"),
        ModelEntry("gemma3-4b", "Gemma 3 4B (Multilingual)", "gemma-3-4b-it.Q4_K_M.gguf", 3.8, "2.5 GB download", 4.0, "Q4_K_M", "https://huggingface.co/unsloth/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf?download=true", "04a43a22e8d2003deda5acc262f68ec1005fa76c735a9962a8c77042a74a7d19"),
        ModelEntry("qwen3-4b", "Qwen3 4B (Everyday)", "qwen3-4b.Q4_K_M.gguf", 3.6, "2.4 GB download", 4.0, "Q4_K_M", "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf?download=true", "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5"),
        ModelEntry("phi4-mini", "Phi-4 Mini 3.8B (Efficient)", "phi-4-mini-instruct.Q4_K_M.gguf", 3.4, "2.3 GB download", 3.8, "Q4_K_M", "https://huggingface.co/unsloth/Phi-4-mini-instruct-GGUF/resolve/main/Phi-4-mini-instruct-Q4_K_M.gguf?download=true", "88c00229914083cd112853aab84ed51b87bdf6b9ce42f532d8c85c7c63b1730a"),
        ModelEntry("llama32-3b", "Llama 3.2 3B (Balanced)", "llama-3.2-3b-instruct.Q4_K_M.gguf", 3.0, "2.0 GB download", 3.0, "Q4_K_M", "https://huggingface.co/lmstudio-community/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf?download=true", "e4f1a04d927b09ec18eb2f233d85ecd760fc2d35cec97e37f8604d3632210d9a"),
        ModelEntry("llama32-1b", "Llama 3.2 1B (Light)", "llama-3.2-1b-instruct.Q4_K_M.gguf", 1.5, "0.8 GB download", 1.0, "Q4_K_M", "https://huggingface.co/lmstudio-community/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true", "f7ede42862ceca07ad1c88a97b67520019c4ac7e5ced250d2e696fa62ab189af"),
        ModelEntry("llama32-1b-q2", "Llama 3.2 1B Ultra-Light (Low RAM)", "llama-3.2-1b-instruct.Q2_K.gguf", 0.7, "0.4 GB download", 1.0, "Q2_K", "https://huggingface.co/unsloth/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q2_K.gguf?download=true", "8b7091a92bc10d70392a91ebe06cd43e1f5048ae0162e88f8fbe8445447ceae8"),
    )

    /** The smallest model — ultimate fallback for unknown/tiny hardware. */
    val smallest: ModelEntry get() = models.last()

    fun entry(id: String): ModelEntry? = models.firstOrNull { it.id == id }
}
