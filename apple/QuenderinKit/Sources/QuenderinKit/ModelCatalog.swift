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

    /// Parsed download URL, or nil if the catalog string is malformed.
    public var downloadURL: URL? { URL(string: urlString) }
}

/// Multi-model catalog, sorted best → smallest. Mirrors `MODEL_CATALOG`.
public enum ModelCatalog {
    public static let models: [ModelEntry] = [
        ModelEntry(
            id: "llama3-8b",
            label: "Llama 3 8B (Best Quality)",
            filename: "llama-3-instruct-8b.Q4_K_M.gguf",
            ramGB: 6.75,
            sizeLabel: "4.7 GB download",
            paramsBillions: 8,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/lmstudio-community/Meta-Llama-3-8B-Instruct-GGUF/resolve/main/Meta-Llama-3-8B-Instruct-Q4_K_M.gguf?download=true"
        ),
        ModelEntry(
            id: "llama32-3b",
            label: "Llama 3.2 3B (Balanced)",
            filename: "llama-3.2-3b-instruct.Q4_K_M.gguf",
            ramGB: 3.0,
            sizeLabel: "2.0 GB download",
            paramsBillions: 3,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/lmstudio-community/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf?download=true"
        ),
        ModelEntry(
            id: "llama32-1b",
            label: "Llama 3.2 1B (Light)",
            filename: "llama-3.2-1b-instruct.Q4_K_M.gguf",
            ramGB: 1.5,
            sizeLabel: "0.8 GB download",
            paramsBillions: 1,
            quantization: "Q4_K_M",
            urlString: "https://huggingface.co/lmstudio-community/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true"
        ),
        ModelEntry(
            id: "llama32-1b-q2",
            label: "Llama 3.2 1B Ultra-Light (Low RAM)",
            filename: "llama-3.2-1b-instruct.Q2_K.gguf",
            ramGB: 0.7,
            sizeLabel: "0.4 GB download",
            paramsBillions: 1,
            quantization: "Q2_K",
            urlString: "https://huggingface.co/lmstudio-community/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q2_K.gguf?download=true"
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
