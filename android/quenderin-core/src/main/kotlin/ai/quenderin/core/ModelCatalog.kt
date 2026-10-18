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
        QuantizationInfo("IQ2_XXS-mixed", 2.4, "Experimental", false),
        QuantizationInfo("PTQ1_0", 1.75, "Experimental", false),
        QuantizationInfo("PQ2_0", 2.13, "Experimental", false),
        QuantizationInfo("Q2_K", 2.625, "Low", false),
        QuantizationInfo("UD-IQ3_XXS", 3.02, "Fair", false),
        QuantizationInfo("Q3_K_M", 3.5, "Fair", false),
        QuantizationInfo("Q4_K_M", 4.5, "Good", true),
        QuantizationInfo("Q5_K_M", 5.5, "High", false),
        QuantizationInfo("Q6_K", 6.5, "Very High", false),
        QuantizationInfo("Q8_0", 8.0, "Excellent", false),
    )

    fun info(id: String): QuantizationInfo? = all.firstOrNull { it.id == id }
}

/** One immutable, independently verified shard of a split GGUF model. */
data class ModelArtifact(
    val filename: String,
    val url: String,
    val sha256: String,
    val downloadBytes: Long,
)

/** A downloadable model "module" — one GGUF or a complete split GGUF set. */
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
    /** Which human languages the model speaks WELL — honest about Russian ("no Russian" is
     *  stated, not omitted; первые пользователи русскоязычные). Null for sideloaded models. */
    val languagesLabel: String? = null,
    /** Exact artifact size when verified upstream, overriding weight-size estimates. */
    val downloadBytes: Long? = null,
    /** Empty preserves the single-file contract; otherwise legacy file fields identify shard one
     * and downloadBytes is the sum of ALL shards. */
    val artifacts: List<ModelArtifact> = emptyList(),
)

/** Multi-family catalog, sorted best → smallest. Mirrors MODEL_CATALOG. */
object ModelCatalog {
    val models: List<ModelEntry> = listOf(
        // Paged MoE: ~3B of 35B params run per token; ramGB is the RESIDENT set (dense spine +
        // hot experts, mmap streams the rest) — not the 13.2 GB file. MemoryFitness hides it on
        // ordinary phones; it exists for the 16 GB+ tablets/laptops the catalog also serves.
        ModelEntry("qwen36-35b-a3b", "Qwen3.6 35B MoE (Best Agent, Big Download)", "qwen3.6-35b-a3b.UD-IQ3_XXS.gguf", 5.5, "13.2 GB download", 35.0, "UD-IQ3_XXS", "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf?download=true", "9c964e657212fea1f24905dd7b0a89b82fd807d19fab0b41da14251b07b88fbe", languagesLabel = "Russian, English, Chinese + 100 more"),
        // Opt-in only: requires verified Prism runtime support and a real memory budget.
        ModelEntry("bonsai2-27b", "Bonsai 2 27B (Experimental)", "Ternary-Bonsai-2-27B-PTQ1_0.gguf", 7.0, "5.95 GB download", 27.36, "PTQ1_0", "https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf/resolve/b072e1d3b35a0a630cece372c2127528e0994386/Ternary-Bonsai-2-27B-PTQ1_0.gguf?download=true", "53107f530aa52eb00912263ab1ee29bd199261c87cd7b4ad4ca1318c1fe33ee3", languagesLabel = "See model card", downloadBytes = 5_946_648_928L),
        ModelEntry("bonsai2-9b", "Bonsai 2 9B (Experimental)", "Ternary-Bonsai-2-9B-PTQ1_0.gguf", 4.0, "2.00 GB download", 8.95, "PTQ1_0", "https://huggingface.co/prism-ml/Ternary-Bonsai-2-9B-gguf/resolve/5b2abb02362efbed46bbe204014b02837778b2c2/Ternary-Bonsai-2-9B-PTQ1_0.gguf?download=true", "3561df7ac7d26a71ffa991ac2db740b10841c3a350aa2676ccd3ff5d428b4e8b", languagesLabel = "See model card", downloadBytes = 1_997_486_976L),
        ModelEntry("bonsai2-4b", "Bonsai 2 4B (Experimental)", "Ternary-Bonsai-2-4B-PTQ1_0.gguf", 2.5, "0.95 GB download", 4.21, "PTQ1_0", "https://huggingface.co/prism-ml/Ternary-Bonsai-2-4B-gguf/resolve/8d6557168168f91ea6697a4a49ed2ef622b53adb/Ternary-Bonsai-2-4B-PTQ1_0.gguf?download=true", "56711263ec9a9ffeaa74a3a0e58dece8127cf9268404746c721113ca76994d60", languagesLabel = "See model card", downloadBytes = 949_549_920L),
        ModelEntry("bonsai2-2b", "Bonsai 2 2B (Experimental)", "Ternary-Bonsai-2-2B-PTQ1_0.gguf", 1.5, "0.43 GB download", 1.88, "PTQ1_0", "https://huggingface.co/prism-ml/Ternary-Bonsai-2-2B-gguf/resolve/683f7be2629342a50987627b40881e54761a2430/Ternary-Bonsai-2-2B-PTQ1_0.gguf?download=true", "36061ad406df8a4903a6db005be350c50fabfaf717f9ef0acf4b76adcd9929fa", languagesLabel = "See model card", downloadBytes = 429_183_456L),
        // Manual text-only models; full-weight RAM estimates precede runtime overhead.
        ModelEntry("minicpm-v47-1b", "MiniCPM-V 4.7 1B (Experimental, text only)", "MiniCPM-V-4_7-1B-Q4_K_M.gguf", 2.0, "0.67 GB download", 1.0, "Q4_K_M", "https://huggingface.co/openbmb/MiniCPM-V-4.7-1B-gguf/resolve/9684c734cfb2e6aaccb0bb52ba58afa9aae92d90/MiniCPM-V-4_7-1B-Q4_K_M.gguf?download=true", "588c6c94c82f756b86dba35c42ed9ba9ec187d65824eb52f039c347df563e63d", languagesLabel = "See model card", downloadBytes = 672_003_680L),
        ModelEntry("minicpm-v47-35b-a3b", "MiniCPM-V 4.7 35B-A3B (Experimental, text only)", "MiniCPM-V-4_7-35B-A3B-Q4_K_M.gguf", 25.0, "21.17 GB download", 35.0, "Q4_K_M", "https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B-gguf/resolve/77ec40de8445999bf3076aeff9ff45d40a2713cc/MiniCPM-V-4_7-35B-A3B-Q4_K_M.gguf?download=true", "bf3d1c67f7843193e4483aebd26c5dea6b6d1f6a06ffa03c2387a6f3cc6d7df5", languagesLabel = "See model card", downloadBytes = 21_166_255_008L),
        ModelEntry("lfm25-24b-a2b", "LFM2.5 24B-A2B (Experimental, text only)", "LFM2.5-24B-A2B-Q4_K_M.gguf", 18.0, "14.53 GB download", 24.0, "Q4_K_M", "https://huggingface.co/LiquidAI/LFM2.5-24B-A2B-GGUF/resolve/0912d33141f77e10705345a6732bfd83f0252fdc/LFM2.5-24B-A2B-Q4_K_M.gguf?download=true", "d3334405b96228eb9908cdebb5c6194908f2da64282bda852afc3a3910c64e7d", languagesLabel = "See model card", downloadBytes = 14_526_258_464L),
        ModelEntry("jais3-0.9b", "Jais 3 0.9B (Experimental, text only)", "Jais-3-0.9B-Q4_K_M.gguf", 2.0, "0.67 GB download", 1.078285824, "Q4_K_M", "https://huggingface.co/IFM/Jais-3-0.9B-GGUF/resolve/ac7c7be976446226ca3da9c9986a678c879b2dce/Jais-3-0.9B-Q4_K_M.gguf?download=true", "e56a4b769c397a1fd2620cf1eec94513debb1664092d0dfad4af01083c2ac3b0", languagesLabel = "See model card", downloadBytes = 666_192_384L),
        ModelEntry("jais3-3.7b", "Jais 3 3.7B (Experimental, text only)", "Jais-3-3.7B-Q4_K_M.gguf", 6.0, "3.16 GB download", 5.05825536, "Q4_K_M", "https://huggingface.co/IFM/Jais-3-3.7B-GGUF/resolve/653cc7bb723a5bb13dfa5a407b1fa035f3d0498b/Jais-3-3.7B-Q4_K_M.gguf?download=true", "d2039e169049f0646f79bc27aec82ffc0842ff9af1bf75bfc16628929636e09a", languagesLabel = "See model card", downloadBytes = 3_156_606_176L),
        ModelEntry("jais3-7b", "Jais 3 7B (Experimental, text only)", "Jais-3-7B-Q4_K_M.gguf", 9.0, "5.59 GB download", 8.99917824, "Q4_K_M", "https://huggingface.co/IFM/Jais-3-7B-GGUF/resolve/ed44d6f2e90f74c341c0291a07e06ae643d82190/Jais-3-7B-Q4_K_M.gguf?download=true", "a8caa7fecf38d064f216f66d3d59641c1fbefdca9756af0703f4a872ab852eeb", languagesLabel = "See model card", downloadBytes = 5_592_226_016L),
        ModelEntry("jais3-32b", "Jais 3 32B (Experimental, text only)", "Jais-3-32B-Q4_K_M.gguf", 28.0, "21.08 GB download", 34.77930496, "Q4_K_M", "https://huggingface.co/IFM/Jais-3-32B-GGUF/resolve/7f88bd89cbf83ccce89d07776ad11f7bd62cc83b/Jais-3-32B-Q4_K_M.gguf?download=true", "75b5f08fd3b00c4934132aa620662d6b4b09dca2df4ee40243296ed94ee11967", languagesLabel = "See model card", downloadBytes = 21_075_786_688L),
        ModelEntry("jais3-mova-36b-a4b", "Jais 3 MoVA 36B-A4B (Experimental, text only)", "Jais-3-MoVA-36B-A4B-Q4_K_M.gguf", 30.0, "22.37 GB download", 37.44479202, "Q4_K_M", "https://huggingface.co/IFM/Jais-3-MoVA-36B-A4B-GGUF/resolve/8b2c5ab2feffeeca416c99ec972e543db6a97dbe/Jais-3-MoVA-36B-A4B-Q4_K_M.gguf?download=true", "ba9df171ff9e39b52cdd684d4e518163d686bc52a2f49195e9af576621abb2dc", languagesLabel = "See model card", downloadBytes = 22_368_019_936L),
        ModelEntry("nemotron35-bolt-74b-a9b", "Nemotron 3.5 Bolt 74B-A9B (Experimental, text only)", "NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB.gguf", 28.0, "22.02 GB download", 74.042720848, "IQ2_XXS-mixed", "https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB-GGUF/resolve/e0fecb69cb3e5e4c5e8a056fa2aec98c78e91246/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB.gguf?download=true", "91d63363e782c8a3d5f4be42816eba8e0d42dd2530bd07a7d0d2dc440599af75", languagesLabel = "See model card", downloadBytes = 22_018_326_528L),
        ModelEntry("muse-spark-open-q2-k", "Muse Spark Open Q2_K (Experimental, text only)", "Muse-Spark-Open-816B-A42B-Q2_K-00001-of-00022.gguf", 330.0, "304.08 GB download · 22 files", 816.0, "Q2_K", "https://huggingface.co/ggml-org/Muse-Spark-Open-816B-A42B-GGUF/resolve/ada96652107984f184027153a77ec250d67ed271/Muse-Spark-Open-816B-A42B-Q2_K-00001-of-00022.gguf", "b2eb6f55ee80b4e444fb1bde4dc89d1181fb9d159758307bf91a4118cce8b267", languagesLabel = "See model card", downloadBytes = 304080474208L, artifacts = MuseModelArtifacts.parts),
        ModelEntry("qwen3-14b", "Qwen3 14B (Best Quality)", "qwen3-14b.Q4_K_M.gguf", 11.0, "9.0 GB download", 14.0, "Q4_K_M", "https://huggingface.co/Qwen/Qwen3-14B-GGUF/resolve/main/Qwen3-14B-Q4_K_M.gguf?download=true", "500a8806e85ee9c83f3ae08420295592451379b4f8cf2d0f41c15dffeb6b81f0", languagesLabel = "Russian, English, Chinese + 100 more"),
        ModelEntry("gemma4-12b", "Gemma 4 12B (Multilingual)", "gemma-4-12b-it.Q4_K_M.gguf", 9.0, "7.1 GB download", 12.0, "Q4_K_M", "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-Q4_K_M.gguf?download=true", "0a270ec9fe6b34f4a0d33992b6135117b484ebc4766ab76b51d4ae8c457e4c42", languagesLabel = "Russian, English + 140 more"),
        ModelEntry("qwen25-coder-7b", "Qwen2.5 Coder 7B (Coding)", "qwen2.5-coder-7b-instruct.Q4_K_M.gguf", 6.5, "4.7 GB download", 7.0, "Q4_K_M", "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf?download=true", "509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c", languagesLabel = "Russian, English, Chinese + 25 more"),
        ModelEntry("deepseek-r1-7b", "DeepSeek-R1 7B (Reasoning)", "deepseek-r1-distill-qwen-7b.Q4_K_M.gguf", 6.5, "4.7 GB download", 7.0, "Q4_K_M", "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf?download=true", "731ece8d06dc7eda6f6572997feb9ee1258db0784827e642909d9b565641937b", languagesLabel = "English & Chinese — weak Russian"),
        ModelEntry("llama3-8b", "Llama 3 8B (Best Quality)", "llama-3-instruct-8b.Q4_K_M.gguf", 6.75, "4.7 GB download", 8.0, "Q4_K_M", "https://huggingface.co/lmstudio-community/Meta-Llama-3-8B-Instruct-GGUF/resolve/main/Meta-Llama-3-8B-Instruct-Q4_K_M.gguf?download=true", "ab9e4eec7e80892fd78f74d9a15d0299f1e22121cea44efd68a7a02a3fe9a1da", languagesLabel = "English-focused — weak Russian"),
        ModelEntry("mistral-7b", "Mistral 7B (All-Rounder)", "mistral-7b-instruct-v0.3.Q4_K_M.gguf", 6.0, "4.1 GB download", 7.0, "Q4_K_M", "https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/Mistral-7B-Instruct-v0.3-Q4_K_M.gguf?download=true", "1270d22c0fbb3d092fb725d4d96c457b7b687a5f5a715abe1e818da303e562b6", languagesLabel = "English + European — weak Russian"),
        ModelEntry("gemma3-4b", "Gemma 3 4B (Multilingual)", "gemma-3-4b-it.Q4_K_M.gguf", 3.8, "2.5 GB download", 4.0, "Q4_K_M", "https://huggingface.co/unsloth/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf?download=true", "04a43a22e8d2003deda5acc262f68ec1005fa76c735a9962a8c77042a74a7d19", languagesLabel = "Russian, English + 140 more"),
        ModelEntry("qwen3-4b", "Qwen3 4B (Everyday)", "qwen3-4b.Q4_K_M.gguf", 3.6, "2.4 GB download", 4.0, "Q4_K_M", "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf?download=true", "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5", languagesLabel = "Russian, English, Chinese + 100 more"),
        ModelEntry("phi4-mini", "Phi-4 Mini 3.8B (Efficient)", "phi-4-mini-instruct.Q4_K_M.gguf", 3.4, "2.3 GB download", 3.8, "Q4_K_M", "https://huggingface.co/unsloth/Phi-4-mini-instruct-GGUF/resolve/main/Phi-4-mini-instruct-Q4_K_M.gguf?download=true", "88c00229914083cd112853aab84ed51b87bdf6b9ce42f532d8c85c7c63b1730a", languagesLabel = "English-focused — weak Russian"),
        ModelEntry("llama32-3b", "Llama 3.2 3B (Balanced)", "llama-3.2-3b-instruct.Q4_K_M.gguf", 3.0, "2.0 GB download", 3.0, "Q4_K_M", "https://huggingface.co/lmstudio-community/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf?download=true", "e4f1a04d927b09ec18eb2f233d85ecd760fc2d35cec97e37f8604d3632210d9a", languagesLabel = "English + 7 more — no Russian"),
        ModelEntry("llama32-1b", "Llama 3.2 1B (Light)", "llama-3.2-1b-instruct.Q4_K_M.gguf", 1.5, "0.8 GB download", 1.0, "Q4_K_M", "https://huggingface.co/lmstudio-community/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true", "f7ede42862ceca07ad1c88a97b67520019c4ac7e5ced250d2e696fa62ab189af", languagesLabel = "English + 7 more — no Russian"),
        ModelEntry("llama32-1b-q2", "Llama 3.2 1B Ultra-Light (Low RAM)", "llama-3.2-1b-instruct.Q2_K.gguf", 0.7, "0.4 GB download", 1.0, "Q2_K", "https://huggingface.co/unsloth/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q2_K.gguf?download=true", "8b7091a92bc10d70392a91ebe06cd43e1f5048ae0162e88f8fbe8445447ceae8", languagesLabel = "English + 7 more — no Russian"),
    )

    /** The smallest model — ultimate fallback for unknown/tiny hardware. */
    val smallest: ModelEntry get() = models.last()

    fun entry(id: String): ModelEntry? = models.firstOrNull { it.id == id }
}
