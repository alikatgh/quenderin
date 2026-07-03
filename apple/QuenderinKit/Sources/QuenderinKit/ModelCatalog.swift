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
        .init(id: "Q2_K",   bitsPerWeight: 2.625, quality: "Low",       summary: "Extreme compression, noticeable quality loss", recommended: false),
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

    /// Parsed download URL, or nil if the catalog string is malformed.
    public var downloadURL: URL? { URL(string: urlString) }

    /// Map to the canonical cross-platform manifest schema (`shared/model-catalog.json`):
    /// `ramGb` and `url`, so iOS can decode the same JSON the desktop emits.
    private enum CodingKeys: String, CodingKey {
        case id, label, filename, sizeLabel, paramsBillions, quantization, sha256
        case ramGB = "ramGb"
        case urlString = "url"
    }
}

/// Multi-model catalog, sorted best → smallest. Mirrors `MODEL_CATALOG`.
public enum ModelCatalog {
    public static let models: [ModelEntry] = [
        ModelEntry(
            id: "qwen3-14b",
            label: "Qwen3 14B (Best Quality)",
            filename: "qwen3-14b.Q4_K_M.gguf",
            ramGB: 11.0,
            sizeLabel: "9.0 GB download",
            paramsBillions: 14,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/Qwen/Qwen3-14B-GGUF/resolve/main/Qwen3-14B-Q4_K_M.gguf?download=true",
            sha256: "500a8806e85ee9c83f3ae08420295592451379b4f8cf2d0f41c15dffeb6b81f0"
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
            sha256: "509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c"
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
            sha256: "731ece8d06dc7eda6f6572997feb9ee1258db0784827e642909d9b565641937b"
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
            sha256: "ab9e4eec7e80892fd78f74d9a15d0299f1e22121cea44efd68a7a02a3fe9a1da"
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
            sha256: "1270d22c0fbb3d092fb725d4d96c457b7b687a5f5a715abe1e818da303e562b6"
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
            sha256: "04a43a22e8d2003deda5acc262f68ec1005fa76c735a9962a8c77042a74a7d19"
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
            sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5"
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
            sha256: "88c00229914083cd112853aab84ed51b87bdf6b9ce42f532d8c85c7c63b1730a"
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
            sha256: "e4f1a04d927b09ec18eb2f233d85ecd760fc2d35cec97e37f8604d3632210d9a"
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
            sha256: "f7ede42862ceca07ad1c88a97b67520019c4ac7e5ced250d2e696fa62ab189af"
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
            sha256: "8b7091a92bc10d70392a91ebe06cd43e1f5048ae0162e88f8fbe8445447ceae8"
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
