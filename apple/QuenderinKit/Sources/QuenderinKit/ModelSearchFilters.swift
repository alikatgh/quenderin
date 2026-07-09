import Foundation

/// Client-side refine of open-catalog (and local/catalog) search — pure + testable.
/// Newbie presets map onto these fields; experts tweak them directly.
public struct ModelSearchFilters: Equatable, Sendable {
    public enum Sort: String, CaseIterable, Sendable {
        case downloads
        case paramsAsc
        case paramsDesc
        case name
    }

    /// Only show repos where at least one quant is estimated to fit this device (after quants load,
    /// or by rough params/RAM heuristic on the repo id alone).
    public var fitsOnly: Bool
    public var excludeGated: Bool
    /// Max model size class in billions of params (nil = no cap).
    public var maxParamsB: Double?
    /// Max single-file download size in GB (applied when quants are known; soft on repo list).
    public var maxDownloadGB: Double?
    /// Quant family filter: "Q4", "Q5", "Q8", "IQ" — nil = any.
    public var quantFamily: String?
    public var sort: Sort

    public init(
        fitsOnly: Bool = false,
        excludeGated: Bool = false,
        maxParamsB: Double? = nil,
        maxDownloadGB: Double? = nil,
        quantFamily: String? = nil,
        sort: Sort = .downloads
    ) {
        self.fitsOnly = fitsOnly
        self.excludeGated = excludeGated
        self.maxParamsB = maxParamsB
        self.maxDownloadGB = maxDownloadGB
        self.quantFamily = quantFamily
        self.sort = sort
    }

    public static let `default` = ModelSearchFilters()

    // MARK: Newbie presets

    /// Green-badge quants only, skip gated, prefer modest downloads.
    public static let runsOnThisMac = ModelSearchFilters(
        fitsOnly: true, excludeGated: true, maxDownloadGB: 8, sort: .downloads
    )
    /// Smaller models for phones / low RAM.
    public static let smallAndFast = ModelSearchFilters(
        fitsOnly: true, excludeGated: true, maxParamsB: 4, maxDownloadGB: 4, quantFamily: "Q4", sort: .paramsAsc
    )
    /// Stronger models that still fit (no hard param floor — user picks quality).
    public static let bestICanRun = ModelSearchFilters(
        fitsOnly: true, excludeGated: false, maxDownloadGB: 12, sort: .paramsDesc
    )

    public var isDefault: Bool {
        self == .default
    }

    // MARK: Apply

    public func apply(to hits: [HFModelHit], totalRAMGB: Double) -> [HFModelHit] {
        var out = hits.filter { hit in
            if excludeGated && hit.gated { return false }
            if let maxP = maxParamsB, hit.estimatedParamsB > maxP + 0.05 { return false }
            if fitsOnly {
                // Before quants load: rough RAM gate from params (same order as MemoryFitness spirit).
                let roughRAM = hit.estimatedParamsB * 0.7 + 0.5
                if roughRAM > totalRAMGB * 0.85 { return false }
            }
            return true
        }
        switch sort {
        case .downloads:
            out.sort { $0.downloads > $1.downloads }
        case .paramsAsc:
            out.sort {
                if $0.estimatedParamsB != $1.estimatedParamsB { return $0.estimatedParamsB < $1.estimatedParamsB }
                return $0.downloads > $1.downloads
            }
        case .paramsDesc:
            out.sort {
                if $0.estimatedParamsB != $1.estimatedParamsB { return $0.estimatedParamsB > $1.estimatedParamsB }
                return $0.downloads > $1.downloads
            }
        case .name:
            out.sort { $0.shortName.localizedCaseInsensitiveCompare($1.shortName) == .orderedAscending }
        }
        return out
    }

    public func apply(to quants: [HFQuant], totalRAMGB: Double) -> [HFQuant] {
        var qs = quants
        if let fam = quantFamily?.uppercased(), !fam.isEmpty {
            qs = qs.filter { $0.quant.uppercased().hasPrefix(fam) || $0.quant.uppercased().contains(fam) }
        }
        if let maxGB = maxDownloadGB {
            qs = qs.filter { $0.sizeGB <= maxGB + 0.05 }
        }
        if fitsOnly {
            qs = qs.filter { q in
                let entry = HuggingFaceCatalog.candidate(from: q, label: q.filename)
                return MemoryFitness.check(model: entry, totalGB: totalRAMGB, freeGB: totalRAMGB).canLoad
            }
        }
        // Prefer runnable (fits) first, then smaller downloads.
        qs.sort { a, b in
            let ea = HuggingFaceCatalog.candidate(from: a, label: a.filename)
            let eb = HuggingFaceCatalog.candidate(from: b, label: b.filename)
            let fa = MemoryFitness.check(model: ea, totalGB: totalRAMGB, freeGB: totalRAMGB)
            let fb = MemoryFitness.check(model: eb, totalGB: totalRAMGB, freeGB: totalRAMGB)
            if fa.canLoad != fb.canLoad { return fa.canLoad && !fb.canLoad }
            if fa.severity != fb.severity {
                // .safe before .tight before unloadable (already filtered)
                return fa.severity == .safe && fb.severity != .safe
            }
            return a.sizeBytes < b.sizeBytes
        }
        return qs
    }

    /// Best quant line for newbies when a row expands.
    public static func recommendedPick(from quants: [HFQuant], totalRAMGB: Double) -> HFQuant? {
        let filters = ModelSearchFilters(fitsOnly: true, quantFamily: "Q4")
        let q4 = filters.apply(to: quants, totalRAMGB: totalRAMGB)
        if let best = q4.first { return best }
        return ModelSearchFilters(fitsOnly: true).apply(to: quants, totalRAMGB: totalRAMGB).first
    }
}
