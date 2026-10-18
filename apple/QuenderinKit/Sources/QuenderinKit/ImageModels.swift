import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ImageModelComponent: Codable, Sendable, Equatable {
    public let role: String
    public let repo: String
    public let revision: String
    public let filename: String
    public let localFilename: String
    public let bytes: Int64
    public let sha256: String
    public let access: String

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(filename)?download=true")!
    }
}

public struct ImageModelDefaults: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let steps: Int
    public let cfg: Double
    public let flowShift: Double
}

public struct ImageModel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let modelKind: Int
    public let license: String
    public let licenseUrl: String
    public let requiresPublisherAccess: Bool
    public let defaults: ImageModelDefaults
    public let components: [ImageModelComponent]

    public var downloadBytes: Int64 { components.reduce(0) { $0 + $1.bytes } }
    public var downloadLabel: String { ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .decimal) }

    public func validate() throws {
        let safeName = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,239}$"#
        func matches(_ value: String, _ pattern: String) -> Bool {
            value.range(of: pattern, options: .regularExpression) != nil
        }
        guard matches(id, safeName), !id.contains(".."), (1...3).contains(modelKind),
              (3...4).contains(components.count), Set(components.map(\.localFilename)).count == components.count,
              Set(components.map(\.role)) == (modelKind == 1 ? Set(["diffusion", "text_encoder", "vae"]) : Set(["diffusion", "text_encoder", "vae", "tokenizer"])),
              defaults.width == 512, defaults.height == 512, (1...50).contains(defaults.steps),
              URL(string: licenseUrl)?.scheme == "https" else {
            throw ImageGenerationError.invalid("The image model manifest is invalid.")
        }
        for component in components {
            guard matches(component.localFilename, safeName), !component.localFilename.contains(".."),
                  matches(component.repo, #"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#),
                  matches(component.revision, #"^[a-f0-9]{40}$"#), matches(component.sha256, #"^[a-f0-9]{64}$"#),
                  component.bytes > 0, component.bytes < 100_000_000_000,
                  !component.filename.split(separator: "/").isEmpty,
                  component.filename.split(separator: "/").allSatisfy({ matches(String($0), safeName) && !$0.contains("..") }),
                  ["public", "publisher-gated"].contains(component.access) else {
                throw ImageGenerationError.invalid("An image model component has invalid provenance.")
            }
        }
    }
}

public struct ImageModelCatalog: Codable, Sendable {
    public let version: Int
    public let models: [ImageModel]

    public static func decode(_ data: Data) throws -> ImageModelCatalog {
        guard data.count <= 1_048_576 else { throw ImageGenerationError.invalid("Image catalog is too large.") }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.version == 1, (1...8).contains(catalog.models.count),
              Set(catalog.models.map(\.id)).count == catalog.models.count else {
            throw ImageGenerationError.invalid("Image catalog is invalid.")
        }
        try catalog.models.forEach { try $0.validate() }
        return catalog
    }

    public static func bundled() throws -> ImageModelCatalog {
        guard let url = Bundle.module.url(forResource: "image-model-catalog", withExtension: "json") else {
            throw ImageGenerationError.invalid("This build has no image model catalog.")
        }
        return try decode(Data(contentsOf: url))
    }
}

public enum ImageGenerationError: LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

public struct ImageResourceBudget: Sendable {
    public static let requiredMemoryBytes: Int64 = 24 * 1_073_741_824
    public let availableMemoryBytes: Int64
    public let freeDiskBytes: Int64

    public static func current() -> ImageResourceBudget {
        var memory = Int64(HardwareProbe.appMemoryBudgetGB() * 1_073_741_824)
        #if os(macOS)
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        memory = status == KERN_SUCCESS
            ? (Int64(statistics.free_count) + Int64(statistics.inactive_count)) * Int64(vm_kernel_page_size) : 0
        #endif
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let disk = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return ImageResourceBudget(availableMemoryBytes: memory, freeDiskBytes: disk)
    }

    public func blockReason(for model: ImageModel, installing: Bool, remainingDownloadBytes: Int64? = nil) -> String? {
        guard availableMemoryBytes >= Self.requiredMemoryBytes else {
            return "This experimental model needs at least 24 GiB of available app memory. Choose a larger device or close other apps."
        }
        let remaining = remainingDownloadBytes ?? model.downloadBytes
        guard remaining >= 0 && remaining <= model.downloadBytes else { return "The remaining image model size is invalid." }
        let diskRequired = (installing ? remaining : 0) + 1_073_741_824
        guard freeDiskBytes >= diskRequired else {
            return "Keep \(ByteCountFormatter.string(fromByteCount: diskRequired, countStyle: .decimal)) free for the remaining model components and image output."
        }
        return nil
    }
}
