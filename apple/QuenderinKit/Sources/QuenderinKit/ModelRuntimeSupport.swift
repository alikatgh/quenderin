import Foundation
#if canImport(llama) && (QUENDERIN_PRISM_LLAMA || QUENDERIN_MUSE_LLAMA)
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

    /// Enabled only by Package.swift's verified patched-source provenance, never by model naming.
    public static var supportsMuse: Bool {
        #if canImport(llama) && QUENDERIN_MUSE_LLAMA
        return quenderin_muse_spark_runtime_abi() == 1
        #else
        return false
        #endif
    }
    public static var supportsWeeklyText: Bool {
        #if canImport(llama) && QUENDERIN_WEEKLY_TEXT_LLAMA
        return quenderin_weekly_text_runtime_abi() == 1
        #else
        return false
        #endif
    }
    public static let weeklyTextUnavailableMessage = "Jais 3 and Nemotron 3.5 require a build with the verified architecture backport. Older Prism runtimes cannot download or load them. Support is experimental text chat only."
    public static func isJais(_ model: ModelEntry) -> Bool {
        [model.id, model.label, model.filename, model.urlString].contains {
            $0.range(of: #"jais[-_ ]?3"#, options: .regularExpression.union(.caseInsensitive)) != nil
        }
    }
    public static func requiresWeeklyTextRuntime(_ model: ModelEntry) -> Bool {
        [model.id, model.label, model.filename, model.urlString].contains {
            $0.range(of: #"jais[-_ ]?3|nemotron[-_ ]?(?:3[._-]?5|35)"#,
                     options: .regularExpression.union(.caseInsensitive)) != nil
        }
    }
    public static let museMaxContextTokens = 4096
    public static let museUnavailableMessage = "Muse Spark Open requires a build with the pinned Muse-compatible local llama.cpp runtime. This build cannot download or load it."
    public static func isMuse(_ model: ModelEntry) -> Bool {
        [model.id, model.label, model.filename, model.urlString].contains(where: isMuseIdentifier)
    }
    private static func isMuseIdentifier(_ value: String) -> Bool {
        let key = value.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        return key.contains("muse-spark") || key.contains("musespark")
    }
    public static func unavailableReason(for model: ModelEntry) -> String {
        if requiresWeeklyTextRuntime(model), !supportsWeeklyText { return weeklyTextUnavailableMessage }
        if ModelArtifactSet.looksLikeSplitFilename(model.filename), !ModelArtifactSet.isMultipart(model) {
            return "This is one file of a split model. Choose a catalog model with the complete verified file manifest."
        }
        if ModelArtifactSet.isMultipart(model) {
            do { _ = try ModelArtifactSet.validate(model) }
            catch { return error.localizedDescription }
        }
        if isMuse(model), !ModelArtifactSet.isMultipart(model) {
            return "Muse Spark requires the complete verified multi-file catalog manifest."
        }
        return isMuse(model) ? museUnavailableMessage : unavailableMessage
    }

    public static let unavailableMessage = "Bonsai, Prism quantizations, MiniCPM-V 4.7 and LFM2.5 24B require a build with the verified Prism llama.cpp runtime. This build cannot download or load them. MiniCPM support is text only."
    public static let bonsaiMaxContextTokens = 4096

    /// Verified language towers only. Projector/image/video inference is a separate engine.
    public static func requiresVerifiedTextRuntime(_ model: ModelEntry) -> Bool {
        [model.id, model.label, model.filename, model.urlString].contains {
            $0.range(of: #"minicpm[-_ ]?v[-_ ]?(?:4[._-]?7|47)|lfm(?:2[._-]?5|25)[-_ ]?24b"#,
                     options: .regularExpression.union(.caseInsensitive)) != nil
        }
    }

    public static func isBonsai(_ model: ModelEntry) -> Bool {
        [model.id, model.label, model.filename, model.urlString].contains { $0.localizedCaseInsensitiveContains("bonsai") }
    }

    public static func requiresPrism(_ model: ModelEntry) -> Bool {
        isBonsai(model) || requiresVerifiedTextRuntime(model) || requiresWeeklyTextRuntime(model)
            || [model.quantization, model.filename, model.urlString].contains { containsPrismFormat($0) }
    }

    public static func supports(_ model: ModelEntry) -> Bool {
        if requiresWeeklyTextRuntime(model), !supportsWeeklyText { return false }
        if (ModelArtifactSet.looksLikeSplitFilename(model.filename) || isMuse(model)) && !ModelArtifactSet.isMultipart(model) { return false }
        if ModelArtifactSet.isMultipart(model), (try? ModelArtifactSet.validate(model)) == nil { return false }
        return (!requiresPrism(model) || supportsBonsai) && (!isMuse(model) || supportsMuse)
    }

    static func blockedDownloadReason(from url: URL, to destination: URL, modelID: String = "") -> String? {
        let identifiers = [url.absoluteString, destination.lastPathComponent, modelID]
        if !supportsWeeklyText, identifiers.contains(where: {
            $0.range(of: #"jais[-_ ]?3|nemotron[-_ ]?(?:3[._-]?5|35)"#,
                     options: .regularExpression.union(.caseInsensitive)) != nil
        }) { return weeklyTextUnavailableMessage }
        if identifiers.contains(where: isMuseIdentifier), !supportsMuse { return museUnavailableMessage }
        let needsPrism = identifiers.contains {
            $0.localizedCaseInsensitiveContains("bonsai") || containsPrismFormat($0)
                || $0.range(of: #"minicpm[-_ ]?v[-_ ]?(?:4[._-]?7|47)|lfm(?:2[._-]?5|25)[-_ ]?24b"#,
                            options: .regularExpression.union(.caseInsensitive)) != nil
        }
        return needsPrism && !supportsBonsai ? unavailableMessage : nil
    }

    /// Conservative estimates at the capped context, with normal overhead added by callers.
    /// Only an exact pinned artifact receives a size-specific floor. Unknown imported Bonsai
    /// keeps the original 7 GB floor; a small-model id alone cannot lower its memory budget.
    static func memoryFootprintGB(_ model: ModelEntry) -> Double {
        if isMuse(model) { return max(330.0, model.ramGB) }
        guard requiresPrism(model) else { return model.ramGB }
        let pinned = ModelCatalog.models.first {
            $0.id == model.id && $0.filename == model.filename && $0.urlString == model.urlString
                && $0.sha256 != nil && $0.sha256 == model.sha256
                && $0.downloadBytes == model.downloadBytes && $0.quantization == model.quantization
                && $0.paramsBillions == model.paramsBillions
        }
        let importedFloor = requiresWeeklyTextRuntime(model)
            ? ([model.id, model.filename].contains { $0.localizedCaseInsensitiveContains("nemotron") } ? 28.0 : 30.0)
            : requiresVerifiedTextRuntime(model)
            ? ([model.id, model.filename].contains { $0.localizedCaseInsensitiveContains("24b") } ? 18.0 : 25.0)
            : 7.0
        return max(pinned?.ramGB ?? importedFloor, model.ramGB.isFinite ? model.ramGB : importedFloor)
    }

    private static func containsPrismFormat(_ value: String) -> Bool {
        let upper = value.uppercased()
        return upper.contains("PTQ1_0") || upper.contains("PQ2_0")
    }
}
