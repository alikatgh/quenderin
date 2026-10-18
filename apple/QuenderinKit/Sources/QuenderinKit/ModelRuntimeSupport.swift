import Foundation
#if canImport(llama) && (QUENDERIN_PRISM_LLAMA || QUENDERIN_MUSE_LLAMA)
import llama
#endif

/// Custom ternary formats need the pinned Prism fork. A model label or app preference cannot
/// enable a missing native implementation; stock and previously built frameworks fail closed.
public enum ModelRuntimeSupport {
    private static func identities(_ model: ModelEntry) -> [String] {
        [model.id, model.label, model.filename, model.urlString] + (model.artifacts ?? []).flatMap { [$0.filename, $0.url] }
    }
    private static func key(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }
    private static func decodedIdentity(_ value: String) -> String {
        guard value.utf16.count <= 16_384 else { return "" }
        return value.removingPercentEncoding ?? value
    }
    static func unsupportedWorkflowReason(identifiers: [String], architecture: String = "", allowPinnedBeam: Bool = false) -> String? {
        if architecture.utf16.count > 256 || identifiers.contains(where: { $0.utf16.count > 16_384 }) { return "The model identity is too long to validate safely." }
        let identifiers = identifiers.map(decodedIdentity)
        let keys = identifiers.map(key), arch = key(architecture)
        if !allowPinnedBeam && (arch == "beam" || identifiers.contains(where: { $0.range(of: #"(?:^|[^a-z0-9])beam(?:[0-9]|[^a-z0-9]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil })) {
            return "Beam requires the complete multipart installer and Harmony chat adapter. Generic chat is unavailable."
        }
        if keys.contains(where: { $0.contains("hymemory") }) { return "Hy-Memory requires a specialized memory-proposal workflow with JSON validation and explicit save approval. Generic chat is unavailable." }
        if keys.contains(where: { $0.contains("supervl") && ($0.contains("nemotron") || $0.contains("120b")) }) { return "Use Ask about an image with the complete Nemotron Super VL model and matching projector." }
        if arch == "step5" || arch == "step5vl" || keys.contains(where: { $0.contains("step5") && !$0.contains("step35") }) { return "Use the Step 5 workflow with the pinned official CUDA gateway on your own host." }
        if arch.contains("graniteswitch") || keys.contains(where: { $0.contains("granite") && $0.contains("switch") && $0.contains("41") }) { return "Use Granite Switch 4.1 chat with a verified converted model and its provenance record." }
        if keys.contains(where: { $0.contains("bolte4b") || ($0.contains("nemotron") && $0.contains("e4b")) }) { return "Nemotron Bolt E4B has no verified public artifact in this release." }
        if keys.contains(where: { $0.contains("nemotron35") }), !keys.contains(where: { $0.range(of: "nemotron35.*bolt.*74b.*a9b", options: .regularExpression) != nil }) {
            return "This Nemotron 3.5 variant has not been validated. Only Bolt 74B-A9B is available as experimental text chat."
        }
        return nil
    }
    public static func unsupportedWorkflowReason(for model: ModelEntry) -> String? {
        unsupportedWorkflowReason(identifiers: identities(model), allowPinnedBeam: isVerifiedBeamManifest(model))
    }
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
    public static var supportsBeam: Bool {
        #if canImport(llama) && QUENDERIN_BEAM_LLAMA
        return quenderin_beam_runtime_abi() == 1
        #else
        return false
        #endif
    }
    public static let beamUnavailableMessage = "Beam requires the verified Beam runtime, all four pinned shards and at least 160 GiB plus context headroom. Experimental text chat only."
    public static func isBeam(_ model: ModelEntry) -> Bool {
        identities(model).contains { decodedIdentity($0).range(of: #"(?:^|[^a-z0-9])beam(?:[0-9]|[^a-z0-9]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil }
    }
    public static func isVerifiedBeamManifest(_ model: ModelEntry) -> Bool {
        guard model.id == "beam-1.0-501b-a23b-ud-iq2-xxs", let pinned = ModelCatalog.entry(id: model.id), model == pinned else { return false }
        return model.artifacts == BeamModelArtifacts.parts && model.downloadBytes == 133885310500
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
        identities(model).contains(where: isWeeklyIdentity)
    }
    static func isWeeklyIdentity(_ value: String) -> Bool {
        let identity = key(decodedIdentity(value))
        return identity.contains("jais3")
            || identity.range(of: "nemotron35.*bolt.*74b.*a9b", options: .regularExpression) != nil
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
        if let reason = unsupportedWorkflowReason(for: model) { return reason }
        if isBeam(model), (!supportsBeam || !isVerifiedBeamManifest(model)) { return beamUnavailableMessage }
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
        isBeam(model) || isBonsai(model) || requiresVerifiedTextRuntime(model) || requiresWeeklyTextRuntime(model)
            || [model.quantization, model.filename, model.urlString].contains { containsPrismFormat($0) }
    }

    public static func supports(_ model: ModelEntry) -> Bool {
        if unsupportedWorkflowReason(for: model) != nil { return false }
        if isBeam(model), (!supportsBeam || !isVerifiedBeamManifest(model)) { return false }
        if requiresWeeklyTextRuntime(model), !supportsWeeklyText { return false }
        if (ModelArtifactSet.looksLikeSplitFilename(model.filename) || isMuse(model)) && !ModelArtifactSet.isMultipart(model) { return false }
        if ModelArtifactSet.isMultipart(model), (try? ModelArtifactSet.validate(model)) == nil { return false }
        return (!requiresPrism(model) || supportsBonsai) && (!isMuse(model) || supportsMuse)
    }

    static func blockedDownloadReason(from url: URL, to destination: URL, modelID: String = "",
                                      weeklyTextRuntimeAvailable: Bool = supportsWeeklyText) -> String? {
        let identifiers = [url.absoluteString, destination.lastPathComponent, modelID]
        let pinnedBeamPart = BeamModelArtifacts.parts.contains { $0.url == url.absoluteString && $0.filename == destination.lastPathComponent }
        if let reason = unsupportedWorkflowReason(identifiers: identifiers, allowPinnedBeam: pinnedBeamPart) { return reason }
        if pinnedBeamPart && !supportsBeam { return beamUnavailableMessage }
        if !weeklyTextRuntimeAvailable, identifiers.contains(where: isWeeklyIdentity) { return weeklyTextUnavailableMessage }
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
        if isBeam(model) { return max(160.0, model.ramGB.isFinite ? model.ramGB : 160.0) }
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
