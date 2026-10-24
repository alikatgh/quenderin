import Foundation
import CryptoKit
#if canImport(Metal)
import Metal
#endif

/// Numeric, generation-owned observations. Conversation content and filesystem paths never enter this type.
public struct InferencePerformanceSample: Codable, Sendable, Equatable {
    public let modelID: String
    public let artifactSHA256: String
    public let runtimeID: String
    public let backendID: String
    public let environmentID: String
    public let contextTokens: Int
    public let promptTokens: Int
    public let prefillTokens: Int
    public let decodedTokens: Int
    public let prefillMs: Double
    public let decodeMs: Double
    public let firstTokenMs: Double
    public let maxGapMs: Double
    public let loadMs: Double
    public let cacheMode: String
    public let thermalState: String
    public let recordedAtMs: Int64

    public init(modelID: String, artifactSHA256: String, runtimeID: String, backendID: String,
                environmentID: String, contextTokens: Int, promptTokens: Int, prefillTokens: Int,
                decodedTokens: Int, prefillMs: Double, decodeMs: Double, firstTokenMs: Double,
                maxGapMs: Double, loadMs: Double, cacheMode: String, thermalState: String, recordedAtMs: Int64) {
        self.modelID = modelID; self.artifactSHA256 = artifactSHA256; self.runtimeID = runtimeID
        self.backendID = backendID; self.environmentID = environmentID; self.contextTokens = contextTokens
        self.promptTokens = promptTokens; self.prefillTokens = prefillTokens; self.decodedTokens = decodedTokens
        self.prefillMs = prefillMs; self.decodeMs = decodeMs; self.firstTokenMs = firstTokenMs
        self.maxGapMs = maxGapMs; self.loadMs = loadMs; self.cacheMode = cacheMode
        self.thermalState = thermalState; self.recordedAtMs = recordedAtMs
    }

    public func isValid(nowMs: Int64) -> Bool {
        guard !modelID.isEmpty, modelID.utf8.count <= 256,
              !modelID.hasPrefix("/"), !modelID.hasPrefix("."), !modelID.contains("\\"),
              modelID.utf8.allSatisfy({ (45...58).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }),
              Self.isDigest(artifactSHA256), Self.isDigest(runtimeID), Self.isDigest(environmentID),
              !backendID.isEmpty, backendID.utf8.count <= 256,
              backendID.utf8.allSatisfy({ (45...46).contains($0) || (48...58).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }),
              (1...262_144).contains(contextTokens), (1...contextTokens).contains(promptTokens),
              (1...promptTokens).contains(prefillTokens), (32...262_144).contains(decodedTokens),
              [prefillMs, decodeMs, firstTokenMs, maxGapMs, loadMs].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 86_400_000 }),
              decodeMs > 0, ["cold", "prefix"].contains(cacheMode),
              ["nominal", "fair", "serious", "critical"].contains(thermalState),
              recordedAtMs >= 0, recordedAtMs <= nowMs else { return false }
        return nowMs - recordedAtMs <= 30 * 86_400_000
    }
    public static func isDigest(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public typealias InferencePerformanceCallback = @Sendable (InferencePerformanceSample) -> Void

/// The registered engine, without implying that requested Metal layers actually executed on a GPU.
public enum InferencePerformanceIdentity {
    public static var backendID: String {
        #if canImport(llama)
        #if QUENDERIN_PRISM_LLAMA
        return "llama-prism"
        #elseif QUENDERIN_MUSE_LLAMA
        return "llama-muse"
        #else
        return "llama-cpp"
        #endif
        #else
        return "unavailable"
        #endif
    }
    public static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Only call after the exact file/set passed integrity verification.
    public static func artifact(_ model: ModelEntry) -> String? {
        if ModelArtifactSet.isMultipart(model) {
            guard let parts = try? ModelArtifactSet.validate(model), !parts.isEmpty else { return nil }
            return digest(parts.map { "\($0.sha256):\($0.downloadBytes)" }.joined(separator: "\n"))
        }
        guard let hash = model.sha256?.lowercased(), InferencePerformanceSample.isDigest(hash) else { return nil }
        return hash
    }
    static func verifiedArtifact(_ model: ModelEntry, firstFile: URL) -> String? {
        guard let artifact = artifact(model) else { return nil }
        if ModelArtifactSet.isMultipart(model) {
            return ModelArtifactSet.isVerified(model, firstFile: firstFile) ? artifact : nil
        }
        guard let identity = ModelArtifactReceipts.Identity.read(firstFile),
              model.downloadBytes == nil || identity.size == model.downloadBytes,
              let hash = model.sha256?.lowercased() else { return nil }
        let part = ModelArtifact(filename: model.filename, url: "", sha256: hash, downloadBytes: identity.size)
        return ModelArtifactReceipts.shared.contains(part, at: firstFile, identity: identity) ? artifact : nil
    }
    static func verifyInstalled(_ model: ModelEntry, firstFile: URL) throws {
        if verifiedArtifact(model, firstFile: firstFile) != nil { return }
        if ModelArtifactSet.isMultipart(model) { try ModelArtifactSet.verify(model, firstFile: firstFile) }
        else {
            let before = ModelArtifactReceipts.Identity.read(firstFile)
            try ModelIntegrity.verify(fileURL: firstFile, expectedSHA256: model.sha256)
            guard before != nil, before == ModelArtifactReceipts.Identity.read(firstFile) else {
                throw ModelArtifactError.changedDuringVerification(model.filename)
            }
        }
        if artifact(model) != nil, verifiedArtifact(model, firstFile: firstFile) == nil {
            throw ModelArtifactError.changedDuringVerification(model.filename)
        }
    }
    private static func acceleratorSignature() -> String {
        #if canImport(Metal)
        #if os(macOS)
        let devices = MTLCopyAllDevices()
        #else
        let devices = MTLCreateSystemDefaultDevice().map { [$0] } ?? []
        #endif
        return devices.map { device in
            let size = device.maxThreadsPerThreadgroup
            return "\(device.name):\(size.width)x\(size.height)x\(size.depth):\(device.hasUnifiedMemory)"
        }.sorted().joined(separator: ";")
        #else
        return "no-metal"
        #endif
    }
    public static func environment(context: Int, cacheType: String, threads: Int, gpuLayers: Int32,
                                   cpuExperts: Bool, batch: Int) -> String {
        let h = HardwareProbe.current()
        // Hardware model/CPU brand and OS build are nonunique. No serial, hostname, account or random device ID.
        return digest([h.chip, String(h.isAppleSilicon), String(ProcessInfo.processInfo.physicalMemory),
                       ProcessInfo.processInfo.operatingSystemVersionString, acceleratorSignature(), backendID, InferencePerformanceRuntime.id,
                       "prism=\(ModelRuntimeSupport.supportsBonsai);muse=\(ModelRuntimeSupport.supportsMuse);beam=\(ModelRuntimeSupport.supportsBeam);weekly=\(ModelRuntimeSupport.supportsWeeklyText)",
                       "ctx=\(context)", "kv=\(cacheType)", "threads=\(threads)", "requestedLayers=\(gpuLayers)",
                       "cpuExperts=\(cpuExperts)", "batch=\(batch)", "mmap;flash-auto;warmup-v1"].joined(separator: "|"))
    }
    static func thermal(_ level: ThermalLevel) -> String {
        switch level { case .nominal: return "nominal"; case .fair: return "fair"; case .serious: return "serious"; case .critical: return "critical" }
    }
}

/// Bounded atomic local history. An I/O failure preserves both the prior file and the in-memory history.
public actor InferencePerformanceStore {
    public static let maximumRecords = 64
    public static let maximumBytes = 131_072
    private let file: URL
    private let write: @Sendable (Data, URL) throws -> Void
    public init(file: URL? = nil, write: @escaping @Sendable (Data, URL) throws -> Void = { data, file in
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }) {
        self.file = file ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("Quenderin/inference-performance-v1.json")
        self.write = write
    }
    public func samples(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [InferencePerformanceSample] {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maximumBytes, let data = try? Data(contentsOf: file), data.count <= Self.maximumBytes,
              let decoded = try? JSONDecoder().decode([InferencePerformanceSample].self, from: data),
              decoded.count <= Self.maximumRecords else { return [] }
        return Self.unique(decoded.filter { $0.isValid(nowMs: nowMs) })
    }
    nonisolated static func unique(_ samples: [InferencePerformanceSample]) -> [InferencePerformanceSample] {
        var result: [InferencePerformanceSample] = []
        for row in samples where !result.contains(row) { result.append(row) }
        return result
    }
    @discardableResult
    public func record(_ sample: InferencePerformanceSample, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        guard sample.isValid(nowMs: nowMs) else { return false }
        let retained = Array(Self.unique(samples(nowMs: nowMs) + [sample]).sorted { $0.recordedAtMs < $1.recordedAtMs }.suffix(Self.maximumRecords))
        do {
            let data = try JSONEncoder().encode(retained)
            guard data.count <= Self.maximumBytes else { return false }
            try write(data, file)
            return true
        } catch { return false }
    }
}

/// An installed model and the admission gates used by Automatic selection.
public struct AutomaticModelCandidate: Sendable {
    public let modelID: String
    public let artifactSHA256: String
    public let runtimeID: String
    public let backendID: String
    public let environmentID: String
    public let contextTokens: Int
    public let installed: Bool
    public let verified: Bool
    public let runtimeAvailable: Bool
    public let fitsMemory: Bool
    public let fitsContext: Bool
    public let fitsDisk: Bool
    public let supportsTask: Bool
    public let qualityEligible: Bool
    /// Nil preserves the shared fixture/request cache mode. Switching candidates explicitly use cold.
    public let cacheMode: String?
    public var admitted: Bool {
        installed && verified && runtimeAvailable && fitsMemory && fitsContext && fitsDisk && supportsTask && qualityEligible
        && InferencePerformanceSample.isDigest(artifactSHA256)
    }
    public init(modelID: String, artifactSHA256: String, runtimeID: String, backendID: String, environmentID: String,
                contextTokens: Int, installed: Bool = true, verified: Bool = true, runtimeAvailable: Bool = true,
                fitsMemory: Bool = true, fitsContext: Bool = true, fitsDisk: Bool = true,
                supportsTask: Bool = true, qualityEligible: Bool = true, cacheMode: String? = nil) {
        self.modelID = modelID; self.artifactSHA256 = artifactSHA256; self.runtimeID = runtimeID
        self.backendID = backendID; self.environmentID = environmentID; self.contextTokens = contextTokens
        self.installed = installed; self.verified = verified; self.runtimeAvailable = runtimeAvailable
        self.fitsMemory = fitsMemory; self.fitsContext = fitsContext; self.fitsDisk = fitsDisk
        self.supportsTask = supportsTask; self.qualityEligible = qualityEligible; self.cacheMode = cacheMode
    }
}

public struct AutomaticModelDecision: Sendable, Equatable {
    public let modelID: String
    public let observed: Bool
    public let predictedMs: Double?
}

public enum AutomaticModelPolicy {
    static func promptBucket(_ tokens: Int) -> Int {
        var upper = 128, bucket = 0
        while tokens > upper && upper < 262_144 { upper *= 4; bucket += 1 }
        return bucket
    }
    private static func median(_ values: [Double]) -> Double {
        let v = values.sorted(), m = values.count / 2
        return v.count % 2 == 0 ? (v[m - 1] + v[m]) / 2 : v[m]
    }
    public static func choose(currentID: String?, candidates: [AutomaticModelCandidate], samples: [InferencePerformanceSample],
                              promptTokens: Int, expectedOutputTokens: Int, cacheMode: String = "cold",
                              nowMs: Int64, thermalNominal: Bool = true, fallbackID: String? = nil) -> AutomaticModelDecision? {
        let eligible = candidates.filter(\.admitted).sorted { $0.modelID < $1.modelID }
        guard !eligible.isEmpty else { return nil }
        let current = eligible.first { $0.modelID == currentID }
        if !thermalNominal && current == nil { return nil }
        func prediction(_ c: AutomaticModelCandidate) -> (Double, Double)? {
            guard thermalNominal, promptTokens > 0, expectedOutputTokens > 0 else { return nil }
            let rows = InferencePerformanceStore.unique(samples.filter {
                $0.isValid(nowMs: nowMs) && $0.modelID == c.modelID && $0.artifactSHA256 == c.artifactSHA256
                && $0.runtimeID == c.runtimeID && $0.backendID == c.backendID && $0.environmentID == c.environmentID
                && $0.contextTokens == c.contextTokens && $0.cacheMode == (c.cacheMode ?? cacheMode) && $0.thermalState == "nominal"
                && promptBucket($0.promptTokens) == promptBucket(promptTokens)
            })
            guard rows.count >= 3 else { return nil }
            let cost = median(rows.map { $0.prefillMs / Double($0.promptTokens) * Double(promptTokens)
                + $0.decodeMs / Double($0.decodedTokens) * Double(expectedOutputTokens) })
            return (cost, median(rows.map(\.loadMs)))
        }
        if let current {
            guard let baseline = prediction(current) else { return .init(modelID: current.modelID, observed: false, predictedMs: nil) }
            let alternatives = eligible.compactMap { c -> AutomaticModelDecision? in
                guard c.modelID != current.modelID, let p = prediction(c), p.0 + p.1 <= baseline.0 * 0.8 else { return nil }
                return .init(modelID: c.modelID, observed: true, predictedMs: p.0 + p.1)
            }.sorted { $0.predictedMs == $1.predictedMs ? $0.modelID < $1.modelID : $0.predictedMs! < $1.predictedMs! }
            return alternatives.first ?? .init(modelID: current.modelID, observed: true, predictedMs: baseline.0)
        }
        let fallback = eligible.first { $0.modelID == fallbackID } ?? eligible[0]
        let measured = prediction(fallback)
        return .init(modelID: fallback.modelID, observed: measured != nil, predictedMs: measured.map { $0.0 + $0.1 })
    }
}
