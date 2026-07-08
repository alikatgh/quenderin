import Foundation

/// Open model discovery over the Hugging Face Hub. The shipped `ModelCatalog` is a curated,
/// SHA-pinned, compatibility-tested set; this lets a user SEARCH the wider Hub for ANY GGUF their
/// hardware can run — honestly labelled (a community upload, not Quenderin-vetted) and still
/// integrity-checkable against HF's own per-file sha256. The network lives behind `ModelSearchProviding`
/// so the resolve/params/fitness logic is unit-tested without a live call.

/// A model repo that matched a search.
public struct HFModelHit: Sendable, Equatable {
    public let id: String        // "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF"
    public let downloads: Int
    public let gated: Bool       // an official gated repo (Meta/Google) needs HF license acceptance
    public init(id: String, downloads: Int, gated: Bool) {
        self.id = id; self.downloads = downloads; self.gated = gated
    }
}

/// One downloadable GGUF quantization inside a repo.
public struct HFQuant: Sendable, Equatable, Identifiable {
    public var id: String { "\(repo)/\(filename)" }
    public let repo: String
    public let filename: String
    public let sizeBytes: Int
    public let sha256: String?   // HF LFS oid — keeps the download verifiable, like the pinned catalog
    public init(repo: String, filename: String, sizeBytes: Int, sha256: String?) {
        self.repo = repo; self.filename = filename; self.sizeBytes = sizeBytes; self.sha256 = sha256
    }
    public var sizeGB: Double { Double(sizeBytes) / 1_073_741_824.0 }
    public var quant: String { HuggingFaceCatalog.quantLabel(filename) }
    public var downloadURL: URL? {
        // Percent-encode the filename: the modern URL parser auto-encodes a space/`#`, but the legacy
        // one on the package's floor targets (macOS 13 / iOS 16) returns nil for an un-encoded name, so
        // a quant like "model (v2)-Q4_K_M.gguf" would be permanently undownloadable there. `repo` is
        // HF-restricted to a URL-safe charset; a `filename` never contains a "/".
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)?download=true")
    }
}

/// The seam — a live HF client in production, a canned one in tests.
public protocol ModelSearchProviding: Sendable {
    func search(_ query: String) async throws -> [HFModelHit]
    func quants(in repo: String) async throws -> [HFQuant]
}

public enum HuggingFaceCatalog {
    /// Parse the quant tag (Q4_K_M, IQ3_XS, Q8_0…) from a gguf filename; "GGUF" if none is found.
    public static func quantLabel(_ filename: String) -> String {
        if let r = filename.range(of: #"(IQ|Q)\d+(_[A-Z0-9]+)*"#, options: [.regularExpression, .caseInsensitive]) {
            return String(filename[r]).uppercased()
        }
        return "GGUF"
    }

    /// Rough params-in-billions from a repo/file name (e.g. "…-8B-…" → 8, "Llama-3.2-1B" → 1). The
    /// LAST `<n>B` token wins, since the leading numbers are usually a version (3.2), not the size.
    public static func estimatedParams(_ name: String) -> Double {
        let lower = name.lowercased()
        guard let rx = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*b\b"#) else { return 7 }
        let matches = rx.matches(in: lower, range: NSRange(lower.startIndex..., in: lower))
        if let last = matches.last, let r = Range(last.range(at: 1), in: lower) {
            return Double(lower[r]) ?? 7
        }
        return 7
    }

    /// Turn a resolved HF quant into a candidate `ModelEntry` the existing download/fitness plumbing
    /// understands. Peak-RAM is estimated (weights + KV/runtime headroom) since HF only gives file size.
    public static func candidate(from q: HFQuant, label: String) -> ModelEntry {
        let params = estimatedParams(q.repo + " " + q.filename)
        let ramGB = q.sizeGB * 1.5 + 0.3
        return ModelEntry(
            id: "hf:\(q.id)",
            label: label,
            // NOT the raw HF filename: two different repos ship the SAME name ("model-Q4_K_M.gguf"),
            // and an HF name can collide with a curated-catalog file — both would overwrite each other
            // in the shared models dir. Namespace the LOCAL file by repo so every download is distinct.
            // (The REMOTE download URL still uses the real HF path; only the on-disk name is namespaced.)
            filename: safeLocalFilename(repo: q.repo, filename: q.filename),
            ramGB: ramGB,
            sizeLabel: String(format: "%.1f GB download", q.sizeGB),
            paramsBillions: params,
            quantization: q.quant,
            urlString: q.downloadURL?.absoluteString ?? "",
            sha256: q.sha256
        )
    }

    /// A collision-safe, filesystem-legal local filename for an HF quant: the repo (sanitised) +
    /// `__` + the original filename, so `owner/Repo-GGUF` + `m-Q4_K_M.gguf` → `owner_Repo-GGUF__m-Q4_K_M.gguf`.
    /// Keeps the `.gguf` extension (magic/GGUF checks + Finder still see a model), and caps the repo part
    /// so a pathological repo name can't overrun the 255-byte filename limit.
    public static func safeLocalFilename(repo: String, filename: String) -> String {
        let slug = repo.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") ? $0 : "_" }
        let cappedSlug = String(String(slug).prefix(100))
        let combined = "\(cappedSlug)__\(filename)"
        // Bound the WHOLE component under the OS's 255-byte-per-name limit — capping only the repo slug
        // left a long community filename able to overrun it (ENAMETOOLONG on the download write). Trim
        // from the tail but KEEP the extension so it still reads as a GGUF. Distinct repos keep distinct
        // slug prefixes, so collision-safety across repos survives the truncation.
        let maxBytes = 200
        guard combined.utf8.count > maxBytes else { return combined }
        let ext = (filename as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var head = combined
        while head.utf8.count + suffix.utf8.count > maxBytes && !head.isEmpty { head.removeLast() }
        return head + suffix
    }

    // MARK: - Pure JSON parsers (testable without a network call)

    public static func parseSearch(_ data: Data) throws -> [HFModelHit] {
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            return HFModelHit(id: id, downloads: (m["downloads"] as? Int) ?? 0, gated: isGated(m["gated"]))
        }
    }

    public static func parseQuants(repo: String, _ data: Data) throws -> [HFQuant] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = obj["siblings"] as? [[String: Any]] else { return [] }
        return siblings.compactMap { s in
            guard let name = s["rfilename"] as? String, name.lowercased().hasSuffix(".gguf") else { return nil }
            let lfs = s["lfs"] as? [String: Any]
            let size = (lfs?["size"] as? Int) ?? (s["size"] as? Int) ?? 0
            return HFQuant(repo: repo, filename: name, sizeBytes: size, sha256: lfs?["oid"] as? String)
        }
    }

    /// HF returns `gated` as `false`, `"auto"`, or `"manual"`. Anything truthy/non-empty means gated.
    private static func isGated(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let s = v as? String { return !s.isEmpty && s.lowercased() != "false" }
        return false
    }
}

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The live client. Read-only public Hub endpoints — no token, no user data sent.
public struct HuggingFaceAPI: ModelSearchProviding {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func search(_ query: String) async throws -> [HFModelHit] {
        var c = URLComponents(string: "https://huggingface.co/api/models")!
        c.queryItems = [
            .init(name: "search", value: query),
            .init(name: "filter", value: "gguf"),
            .init(name: "sort", value: "downloads"),
            .init(name: "direction", value: "-1"),
            .init(name: "limit", value: "25"),
        ]
        let (data, _) = try await session.data(from: c.url!)
        return try HuggingFaceCatalog.parseSearch(data)
    }

    public func quants(in repo: String) async throws -> [HFQuant] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)?blobs=true")!
        let (data, _) = try await session.data(from: url)
        return try HuggingFaceCatalog.parseQuants(repo: repo, data)
    }
}
