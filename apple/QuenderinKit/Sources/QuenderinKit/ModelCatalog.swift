import Foundation

// Ported faithfully from `quenderin/src/constants.ts`. Keep the two in sync —
// the desktop app and the mobile app must recommend the SAME model for the SAME
// hardware, or the "download → ready" promise breaks across platforms.

/// Quantization reference — bits-per-weight and quality tradeoffs.
/// Mirrors `QUANTIZATION_INFO`.
public struct QuantizationInfo: Sendable, Hashable, Codable {
    public let id: String
    public let bitsPerWeight: Double
    public let quality: String
    public let summary: String
    public let recommended: Bool
}

public enum Quantization {
    public static let all: [QuantizationInfo] = [
        .init(id: "IQ2_XXS-mixed", bitsPerWeight: 2.4, quality: "Experimental", summary: "Mixed IQ2 experts, NVFP4 state-space weights and Q8 embeddings; exact catalog size applies", recommended: false),
        .init(id: "PTQ1_0", bitsPerWeight: 1.75, quality: "Experimental", summary: "Prism ternary quantization; requires the Prism runtime", recommended: false),
        .init(id: "PQ2_0", bitsPerWeight: 2.13, quality: "Experimental", summary: "Prism quantization; requires the Prism runtime", recommended: false),
        .init(id: "Q2_K",   bitsPerWeight: 2.625, quality: "Low",       summary: "Extreme compression, noticeable quality loss", recommended: false),
        .init(id: "UD-IQ3_XXS", bitsPerWeight: 3.02, quality: "Fair",   summary: "Unsloth dynamic 3-bit — keeps critical layers higher-precision", recommended: false),
        .init(id: "Q3_K_M", bitsPerWeight: 3.5,   quality: "Fair",      summary: "Moderate compression",                         recommended: false),
        .init(id: "Q4_K_M", bitsPerWeight: 4.5,   quality: "Good",      summary: "Best balance of quality and size",             recommended: true),
        .init(id: "Q5_K_M", bitsPerWeight: 5.5,   quality: "High",      summary: "Near original quality",                        recommended: false),
        .init(id: "Q6_K",   bitsPerWeight: 6.5,   quality: "Very High", summary: "Minimal quality loss",                         recommended: false),
        .init(id: "Q8_0",   bitsPerWeight: 8.0,   quality: "Excellent", summary: "Best quantized quality",                       recommended: false),
    ]

    public static func info(id: String) -> QuantizationInfo? {
        all.first { $0.id == id }
    }
}

/// One immutable, hash-pinned part of a split GGUF model. All parts share a directory.
public struct ModelArtifact: Sendable, Hashable, Codable {
    public let filename: String
    public let url: String
    public let sha256: String
    public let downloadBytes: Int64

    public init(filename: String, url: String, sha256: String, downloadBytes: Int64) {
        self.filename = filename
        self.url = url
        self.sha256 = sha256
        self.downloadBytes = downloadBytes
    }
}

/// A downloadable model "module" — the unit a device pulls down to become useful.
/// Mirrors an entry of `MODEL_CATALOG`.
public struct ModelEntry: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let label: String
    public let filename: String
    /// Estimated peak RAM footprint (GB) including context/KV-cache overhead.
    public let ramGB: Double
    public let sizeLabel: String
    public let paramsBillions: Double
    public let quantization: String
    public let urlString: String
    /// Expected GGUF file SHA-256 (lowercase hex) for post-download integrity
    /// verification. Optional — when nil, only the GGUF magic header is checked.
    public let sha256: String?
    /// Exact artifact size when verified upstream; takes precedence over weight-size estimates.
    public let downloadBytes: Int64?
    /// Nil/empty preserves legacy single-file downloads. Nonempty is the complete ordered set.
    public let artifacts: [ModelArtifact]?
    /// Which human languages the model speaks WELL — honest and explicit about Russian
    /// (первые пользователи русскоязычные): "no Russian" is stated, not omitted. Family-level
    /// truth, not marketing. Optional: sideloaded/HF models don't carry it.
    public let languagesLabel: String?

    /// Parsed download URL, or nil if the catalog string is malformed.
    public var downloadURL: URL? { URL(string: urlString) }

    /// Map to the canonical cross-platform manifest schema (`shared/model-catalog.json`):
    /// `ramGb` and `url`, so iOS can decode the same JSON the desktop emits.
    /// (`languagesLabel` decodes from `languages`; optional, so entries persisted by older
    /// builds — SideloadedModels JSON — still decode.)
    private enum CodingKeys: String, CodingKey {
        case id, label, filename, sizeLabel, paramsBillions, quantization, sha256, downloadBytes, artifacts
        case ramGB = "ramGb"
        case urlString = "url"
        case languagesLabel = "languages"
    }

    public init(id: String, label: String, filename: String, ramGB: Double, sizeLabel: String,
                paramsBillions: Double, quantization: String, urlString: String,
                sha256: String?, languagesLabel: String? = nil, downloadBytes: Int64? = nil,
                artifacts: [ModelArtifact]? = nil) {
        self.id = id
        self.label = label
        self.filename = filename
        self.ramGB = ramGB
        self.sizeLabel = sizeLabel
        self.paramsBillions = paramsBillions
        self.quantization = quantization
        self.urlString = urlString
        self.sha256 = sha256
        self.downloadBytes = downloadBytes
        self.artifacts = artifacts
        self.languagesLabel = languagesLabel
    }
}

/// Multi-model catalog, sorted best → smallest. Mirrors `MODEL_CATALOG`.
public enum ModelCatalog {
    public static let models: [ModelEntry] = [
        // Paged MoE: only ~3B of 35B params run per token, so with mmap the OS page cache
        // streams the experts from disk — ramGB is the RESIDENT set (dense spine + hot
        // experts, MoEShape formula), NOT the 13.2 GB file. Needs a fast SSD; on machines
        // where the file exceeds the app budget the engine runs it CPU-only (GpuOffloadPolicy).
        ModelEntry(
            id: "qwen36-35b-a3b",
            label: "Qwen3.6 35B MoE (Best Agent, Big Download)",
            filename: "qwen3.6-35b-a3b.UD-IQ3_XXS.gguf",
            ramGB: 5.5,
            sizeLabel: "13.2 GB download",
            paramsBillions: 35,
            quantization: "UD-IQ3_XXS",
            urlString: "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf?download=true",
            sha256: "9c964e657212fea1f24905dd7b0a89b82fd807d19fab0b41da14251b07b88fbe",
            languagesLabel: "Russian, English, Chinese + 100 more"
        ),
        // Opt-in only: this hybrid ternary model needs a verified Prism runtime and a real RAM gate.
        ModelEntry(
            id: "bonsai2-27b",
            label: "Bonsai 2 27B (Experimental)",
            filename: "Ternary-Bonsai-2-27B-PTQ1_0.gguf",
            ramGB: 7.0,
            sizeLabel: "5.95 GB download",
            paramsBillions: 27.36,
            quantization: "PTQ1_0",
            urlString: "https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf/resolve/b072e1d3b35a0a630cece372c2127528e0994386/Ternary-Bonsai-2-27B-PTQ1_0.gguf?download=true",
            sha256: "53107f530aa52eb00912263ab1ee29bd199261c87cd7b4ad4ca1318c1fe33ee3",
            languagesLabel: "See model card",
            downloadBytes: 5_946_648_928
        ),
        ModelEntry(
            id: "bonsai2-9b",
            label: "Bonsai 2 9B (Experimental)",
            filename: "Ternary-Bonsai-2-9B-PTQ1_0.gguf",
            ramGB: 4.0,
            sizeLabel: "2.00 GB download",
            paramsBillions: 8.95,
            quantization: "PTQ1_0",
            urlString: "https://huggingface.co/prism-ml/Ternary-Bonsai-2-9B-gguf/resolve/5b2abb02362efbed46bbe204014b02837778b2c2/Ternary-Bonsai-2-9B-PTQ1_0.gguf?download=true",
            sha256: "3561df7ac7d26a71ffa991ac2db740b10841c3a350aa2676ccd3ff5d428b4e8b",
            languagesLabel: "See model card",
            downloadBytes: 1_997_486_976
        ),
        ModelEntry(
            id: "bonsai2-4b",
            label: "Bonsai 2 4B (Experimental)",
            filename: "Ternary-Bonsai-2-4B-PTQ1_0.gguf",
            ramGB: 2.5,
            sizeLabel: "0.95 GB download",
            paramsBillions: 4.21,
            quantization: "PTQ1_0",
            urlString: "https://huggingface.co/prism-ml/Ternary-Bonsai-2-4B-gguf/resolve/8d6557168168f91ea6697a4a49ed2ef622b53adb/Ternary-Bonsai-2-4B-PTQ1_0.gguf?download=true",
            sha256: "56711263ec9a9ffeaa74a3a0e58dece8127cf9268404746c721113ca76994d60",
            languagesLabel: "See model card",
            downloadBytes: 949_549_920
        ),
        ModelEntry(
            id: "bonsai2-2b",
            label: "Bonsai 2 2B (Experimental)",
            filename: "Ternary-Bonsai-2-2B-PTQ1_0.gguf",
            ramGB: 1.5,
            sizeLabel: "0.43 GB download",
            paramsBillions: 1.88,
            quantization: "PTQ1_0",
            urlString: "https://huggingface.co/prism-ml/Ternary-Bonsai-2-2B-gguf/resolve/683f7be2629342a50987627b40881e54761a2430/Ternary-Bonsai-2-2B-PTQ1_0.gguf?download=true",
            sha256: "36061ad406df8a4903a6db005be350c50fabfaf717f9ef0acf4b76adcd9929fa",
            languagesLabel: "See model card",
            downloadBytes: 429_183_456
        ),
        // Manual text-only models; RAM estimates cover the full weights before runtime overhead.
        ModelEntry(
            id: "minicpm-v47-1b",
            label: "MiniCPM-V 4.7 1B (Experimental, text only)",
            filename: "MiniCPM-V-4_7-1B-Q4_K_M.gguf",
            ramGB: 2.0,
            sizeLabel: "0.67 GB download",
            paramsBillions: 1,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/openbmb/MiniCPM-V-4.7-1B-gguf/resolve/9684c734cfb2e6aaccb0bb52ba58afa9aae92d90/MiniCPM-V-4_7-1B-Q4_K_M.gguf?download=true",
            sha256: "588c6c94c82f756b86dba35c42ed9ba9ec187d65824eb52f039c347df563e63d",
            languagesLabel: "See model card",
            downloadBytes: 672_003_680
        ),
        ModelEntry(
            id: "minicpm-v47-35b-a3b",
            label: "MiniCPM-V 4.7 35B-A3B (Experimental, text only)",
            filename: "MiniCPM-V-4_7-35B-A3B-Q4_K_M.gguf",
            ramGB: 25.0,
            sizeLabel: "21.17 GB download",
            paramsBillions: 35,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B-gguf/resolve/77ec40de8445999bf3076aeff9ff45d40a2713cc/MiniCPM-V-4_7-35B-A3B-Q4_K_M.gguf?download=true",
            sha256: "bf3d1c67f7843193e4483aebd26c5dea6b6d1f6a06ffa03c2387a6f3cc6d7df5",
            languagesLabel: "See model card",
            downloadBytes: 21_166_255_008
        ),
        ModelEntry(
            id: "lfm25-24b-a2b",
            label: "LFM2.5 24B-A2B (Experimental, text only)",
            filename: "LFM2.5-24B-A2B-Q4_K_M.gguf",
            ramGB: 18.0,
            sizeLabel: "14.53 GB download",
            paramsBillions: 24,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/LiquidAI/LFM2.5-24B-A2B-GGUF/resolve/0912d33141f77e10705345a6732bfd83f0252fdc/LFM2.5-24B-A2B-Q4_K_M.gguf?download=true",
            sha256: "d3334405b96228eb9908cdebb5c6194908f2da64282bda852afc3a3910c64e7d",
            languagesLabel: "See model card",
            downloadBytes: 14_526_258_464
        ),
        ModelEntry(
            id: "jais3-0.9b",
            label: "Jais 3 0.9B (Experimental, text only)",
            filename: "Jais-3-0.9B-Q4_K_M.gguf",
            ramGB: 2.0,
            sizeLabel: "0.67 GB download",
            paramsBillions: 1.078285824,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/IFM/Jais-3-0.9B-GGUF/resolve/ac7c7be976446226ca3da9c9986a678c879b2dce/Jais-3-0.9B-Q4_K_M.gguf?download=true",
            sha256: "e56a4b769c397a1fd2620cf1eec94513debb1664092d0dfad4af01083c2ac3b0",
            languagesLabel: "See model card",
            downloadBytes: 666_192_384
        ),
        ModelEntry(
            id: "jais3-3.7b",
            label: "Jais 3 3.7B (Experimental, text only)",
            filename: "Jais-3-3.7B-Q4_K_M.gguf",
            ramGB: 6.0,
            sizeLabel: "3.16 GB download",
            paramsBillions: 5.05825536,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/IFM/Jais-3-3.7B-GGUF/resolve/653cc7bb723a5bb13dfa5a407b1fa035f3d0498b/Jais-3-3.7B-Q4_K_M.gguf?download=true",
            sha256: "d2039e169049f0646f79bc27aec82ffc0842ff9af1bf75bfc16628929636e09a",
            languagesLabel: "See model card",
            downloadBytes: 3_156_606_176
        ),
        ModelEntry(
            id: "jais3-7b",
            label: "Jais 3 7B (Experimental, text only)",
            filename: "Jais-3-7B-Q4_K_M.gguf",
            ramGB: 9.0,
            sizeLabel: "5.59 GB download",
            paramsBillions: 8.99917824,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/IFM/Jais-3-7B-GGUF/resolve/ed44d6f2e90f74c341c0291a07e06ae643d82190/Jais-3-7B-Q4_K_M.gguf?download=true",
            sha256: "a8caa7fecf38d064f216f66d3d59641c1fbefdca9756af0703f4a872ab852eeb",
            languagesLabel: "See model card",
            downloadBytes: 5_592_226_016
        ),
        ModelEntry(
            id: "jais3-32b",
            label: "Jais 3 32B (Experimental, text only)",
            filename: "Jais-3-32B-Q4_K_M.gguf",
            ramGB: 28.0,
            sizeLabel: "21.08 GB download",
            paramsBillions: 34.77930496,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/IFM/Jais-3-32B-GGUF/resolve/7f88bd89cbf83ccce89d07776ad11f7bd62cc83b/Jais-3-32B-Q4_K_M.gguf?download=true",
            sha256: "75b5f08fd3b00c4934132aa620662d6b4b09dca2df4ee40243296ed94ee11967",
            languagesLabel: "See model card",
            downloadBytes: 21_075_786_688
        ),
        ModelEntry(
            id: "jais3-mova-36b-a4b",
            label: "Jais 3 MoVA 36B-A4B (Experimental, text only)",
            filename: "Jais-3-MoVA-36B-A4B-Q4_K_M.gguf",
            ramGB: 30.0,
            sizeLabel: "22.37 GB download",
            paramsBillions: 37.44479202,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/IFM/Jais-3-MoVA-36B-A4B-GGUF/resolve/8b2c5ab2feffeeca416c99ec972e543db6a97dbe/Jais-3-MoVA-36B-A4B-Q4_K_M.gguf?download=true",
            sha256: "ba9df171ff9e39b52cdd684d4e518163d686bc52a2f49195e9af576621abb2dc",
            languagesLabel: "See model card",
            downloadBytes: 22_368_019_936
        ),
        ModelEntry(
            id: "nemotron35-bolt-74b-a9b",
            label: "Nemotron 3.5 Bolt 74B-A9B (Experimental, text only)",
            filename: "NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB.gguf",
            ramGB: 28.0,
            sizeLabel: "22.02 GB download",
            paramsBillions: 74.042720848,
            quantization: "IQ2_XXS-mixed",
            urlString: "https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB-GGUF/resolve/e0fecb69cb3e5e4c5e8a056fa2aec98c78e91246/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB.gguf?download=true",
            sha256: "91d63363e782c8a3d5f4be42816eba8e0d42dd2530bd07a7d0d2dc440599af75",
            languagesLabel: "See model card",
            downloadBytes: 22_018_326_528
        ),
        .init(id: "muse-spark-open-q2-k", label: "Muse Spark Open Q2_K (Experimental, text only)", filename: "Muse-Spark-Open-816B-A42B-Q2_K-00001-of-00022.gguf", ramGB: 330.0, sizeLabel: "304.08 GB download · 22 files", paramsBillions: 816, quantization: "Q2_K", urlString: "https://huggingface.co/ggml-org/Muse-Spark-Open-816B-A42B-GGUF/resolve/ada96652107984f184027153a77ec250d67ed271/Muse-Spark-Open-816B-A42B-Q2_K-00001-of-00022.gguf", sha256: "b2eb6f55ee80b4e444fb1bde4dc89d1181fb9d159758307bf91a4118cce8b267", languagesLabel: "See model card", downloadBytes: 304080474208, artifacts: MuseModelArtifacts.parts),
        ModelEntry(
            id: "qwen3-14b",
            label: "Qwen3 14B (Best Quality)",
            filename: "qwen3-14b.Q4_K_M.gguf",
            ramGB: 11.0,
            sizeLabel: "9.0 GB download",
            paramsBillions: 14,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/Qwen/Qwen3-14B-GGUF/resolve/main/Qwen3-14B-Q4_K_M.gguf?download=true",
            sha256: "500a8806e85ee9c83f3ae08420295592451379b4f8cf2d0f41c15dffeb6b81f0",
            languagesLabel: "Russian, English, Chinese + 100 more"
        ),
        ModelEntry(
            id: "gemma4-12b",
            label: "Gemma 4 12B (Multilingual)",
            filename: "gemma-4-12b-it.Q4_K_M.gguf",
            ramGB: 9.0,
            sizeLabel: "7.1 GB download",
            paramsBillions: 12,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-Q4_K_M.gguf?download=true",
            sha256: "0a270ec9fe6b34f4a0d33992b6135117b484ebc4766ab76b51d4ae8c457e4c42",
            languagesLabel: "Russian, English + 140 more"
        ),
        ModelEntry(
            id: "qwen25-coder-7b",
            label: "Qwen2.5 Coder 7B (Coding)",
            filename: "qwen2.5-coder-7b-instruct.Q4_K_M.gguf",
            ramGB: 6.5,
            sizeLabel: "4.7 GB download",
            paramsBillions: 7,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf?download=true",
            sha256: "509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c",
            languagesLabel: "Russian, English, Chinese + 25 more"
        ),
        ModelEntry(
            id: "deepseek-r1-7b",
            label: "DeepSeek-R1 7B (Reasoning)",
            filename: "deepseek-r1-distill-qwen-7b.Q4_K_M.gguf",
            ramGB: 6.5,
            sizeLabel: "4.7 GB download",
            paramsBillions: 7,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf?download=true",
            sha256: "731ece8d06dc7eda6f6572997feb9ee1258db0784827e642909d9b565641937b",
            languagesLabel: "English & Chinese — weak Russian"
        ),
        ModelEntry(
            id: "llama3-8b",
            label: "Llama 3 8B (Best Quality)",
            filename: "llama-3-instruct-8b.Q4_K_M.gguf",
            ramGB: 6.75,
            sizeLabel: "4.7 GB download",
            paramsBillions: 8,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/lmstudio-community/Meta-Llama-3-8B-Instruct-GGUF/resolve/main/Meta-Llama-3-8B-Instruct-Q4_K_M.gguf?download=true",
            sha256: "ab9e4eec7e80892fd78f74d9a15d0299f1e22121cea44efd68a7a02a3fe9a1da",
            languagesLabel: "English-focused — weak Russian"
        ),
        ModelEntry(
            id: "mistral-7b",
            label: "Mistral 7B (All-Rounder)",
            filename: "mistral-7b-instruct-v0.3.Q4_K_M.gguf",
            ramGB: 6.0,
            sizeLabel: "4.1 GB download",
            paramsBillions: 7,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/Mistral-7B-Instruct-v0.3-Q4_K_M.gguf?download=true",
            sha256: "1270d22c0fbb3d092fb725d4d96c457b7b687a5f5a715abe1e818da303e562b6",
            languagesLabel: "English + European — weak Russian"
        ),
        ModelEntry(
            id: "gemma3-4b",
            label: "Gemma 3 4B (Multilingual)",
            filename: "gemma-3-4b-it.Q4_K_M.gguf",
            ramGB: 3.8,
            sizeLabel: "2.5 GB download",
            paramsBillions: 4,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/unsloth/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf?download=true",
            sha256: "04a43a22e8d2003deda5acc262f68ec1005fa76c735a9962a8c77042a74a7d19",
            languagesLabel: "Russian, English + 140 more"
        ),
        ModelEntry(
            id: "qwen3-4b",
            label: "Qwen3 4B (Everyday)",
            filename: "qwen3-4b.Q4_K_M.gguf",
            ramGB: 3.6,
            sizeLabel: "2.4 GB download",
            paramsBillions: 4,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf?download=true",
            sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5",
            languagesLabel: "Russian, English, Chinese + 100 more"
        ),
        ModelEntry(
            id: "phi4-mini",
            label: "Phi-4 Mini 3.8B (Efficient)",
            filename: "phi-4-mini-instruct.Q4_K_M.gguf",
            ramGB: 3.4,
            sizeLabel: "2.3 GB download",
            paramsBillions: 3.8,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/unsloth/Phi-4-mini-instruct-GGUF/resolve/main/Phi-4-mini-instruct-Q4_K_M.gguf?download=true",
            sha256: "88c00229914083cd112853aab84ed51b87bdf6b9ce42f532d8c85c7c63b1730a",
            languagesLabel: "English-focused — weak Russian"
        ),
        ModelEntry(
            id: "llama32-3b",
            label: "Llama 3.2 3B (Balanced)",
            filename: "llama-3.2-3b-instruct.Q4_K_M.gguf",
            ramGB: 3.0,
            sizeLabel: "2.0 GB download",
            paramsBillions: 3,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/lmstudio-community/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf?download=true",
            sha256: "e4f1a04d927b09ec18eb2f233d85ecd760fc2d35cec97e37f8604d3632210d9a",
            languagesLabel: "English + 7 more — no Russian"
        ),
        ModelEntry(
            id: "llama32-1b",
            label: "Llama 3.2 1B (Light)",
            filename: "llama-3.2-1b-instruct.Q4_K_M.gguf",
            ramGB: 1.5,
            sizeLabel: "0.8 GB download",
            paramsBillions: 1,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/lmstudio-community/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true",
            sha256: "f7ede42862ceca07ad1c88a97b67520019c4ac7e5ced250d2e696fa62ab189af",
            languagesLabel: "English + 7 more — no Russian"
        ),
        ModelEntry(
            id: "llama32-1b-q2",
            label: "Llama 3.2 1B Ultra-Light (Low RAM)",
            filename: "llama-3.2-1b-instruct.Q2_K.gguf",
            ramGB: 0.7,
            sizeLabel: "0.4 GB download",
            paramsBillions: 1,
            quantization: "Q2_K",
            urlString: "https://huggingface.co/unsloth/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q2_K.gguf?download=true",
            sha256: "8b7091a92bc10d70392a91ebe06cd43e1f5048ae0162e88f8fbe8445447ceae8",
            languagesLabel: "English + 7 more — no Russian"
        ),
    ]

    /// The smallest model — ultimate fallback for unknown/tiny hardware.
    public static var smallest: ModelEntry { models[models.count - 1] }

    public static func entry(id: String) -> ModelEntry? {
        models.first { $0.id == id }
    }
}

/// A RAM band → max model size + quantization. Mirrors `MODEL_RECOMMENDATIONS`.
public struct HardwareTier: Sendable, Hashable {
    public let minRAMGB: Double
    /// Exclusive upper bound; `.infinity` for the top tier.
    public let maxRAMGB: Double
    public let maxParamsBillions: Double
    public let quantization: String
}

public enum HardwareTiers {
    public static let all: [HardwareTier] = [
        HardwareTier(minRAMGB: 1,  maxRAMGB: 2,         maxParamsBillions: 1,    quantization: "Q4_K_M"),
        HardwareTier(minRAMGB: 2,  maxRAMGB: 3,         maxParamsBillions: 1.5,  quantization: "Q4_K_M"),
        HardwareTier(minRAMGB: 3,  maxRAMGB: 4,         maxParamsBillions: 1.5,  quantization: "Q4_K_M"),
        HardwareTier(minRAMGB: 4,  maxRAMGB: 6,         maxParamsBillions: 3,    quantization: "Q4_K_M"),
        HardwareTier(minRAMGB: 6,  maxRAMGB: 8,         maxParamsBillions: 4,    quantization: "Q4_K_M"),
        HardwareTier(minRAMGB: 8,  maxRAMGB: 12,        maxParamsBillions: 8,    quantization: "Q4_K_M"),
        HardwareTier(minRAMGB: 12, maxRAMGB: 16,        maxParamsBillions: 13,   quantization: "Q4_K_M"),
        HardwareTier(minRAMGB: 16, maxRAMGB: 32,        maxParamsBillions: 30,   quantization: "Q4_K_M"),
        HardwareTier(minRAMGB: 32, maxRAMGB: .infinity, maxParamsBillions: 70,   quantization: "Q4_K_M"),
    ]
}
