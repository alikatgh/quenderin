import Foundation
#if canImport(llama) && QUENDERIN_PRISM_LLAMA
import llama
#endif

/// Custom ternary formats need the pinned Prism fork. A model label or app preference cannot
/// enable a missing native implementation; stock and previously built frameworks fail closed.
public enum ModelRuntimeSupport {
    public static var supportsBonsai: Bool {
        #if canImport(llama) && QUENDERIN_PRISM_LLAMA
        var types = Set<String>()
        for index in 0..<GGML_TYPE_COUNT.rawValue {
            if let name = ggml_type_name(ggml_type(rawValue: index)) {
                types.insert(String(cString: name).uppercased())
            }
        }
        return types.contains("PTQ1_0") && types.contains("PQ2_0")
        #else
        return false
        #endif
    }

    public static let unavailableMessage = "Bonsai and Prism quantizations require an experimental build with the pinned Prism llama.cpp runtime. This build cannot download or load them."
    public static let bonsaiMaxContextTokens = 4096

    public static func isBonsai(_ model: ModelEntry) -> Bool {
        [model.id, model.label, model.filename, model.urlString].contains { $0.localizedCaseInsensitiveContains("bonsai") }
    }

    public static func requiresPrism(_ model: ModelEntry) -> Bool {
        isBonsai(model) || [model.quantization, model.filename, model.urlString].contains { containsPrismFormat($0) }
    }

    public static func supports(_ model: ModelEntry) -> Bool {
        !requiresPrism(model) || supportsBonsai
    }

    static func blockedDownloadReason(from url: URL, to destination: URL, modelID: String = "") -> String? {
        let identifiers = [url.absoluteString, destination.lastPathComponent, modelID]
        let needsPrism = identifiers.contains { $0.localizedCaseInsensitiveContains("bonsai") || containsPrismFormat($0) }
        return needsPrism && !supportsBonsai ? unavailableMessage : nil
    }

    /// 7 GB is a conservative floor for this artifact, not its 5.95 GB file size. Apply normal
    /// large-model overhead too; do not use a dense 27B KV formula for the hybrid architecture.
    static func memoryFootprintGB(_ model: ModelEntry) -> Double {
        isBonsai(model) ? max(7.0, model.ramGB) : model.ramGB
    }

    private static func containsPrismFormat(_ value: String) -> Bool {
        let upper = value.uppercased()
        return upper.contains("PTQ1_0") || upper.contains("PQ2_0")
    }
}
