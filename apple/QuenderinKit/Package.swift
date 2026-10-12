// swift-tools-version: 6.0
import PackageDescription
import Foundation

// QuenderinKit — the portable "brain" of Quenderin's offline-autonomy vision.
// Pure Foundation, zero UI dependencies, so it compiles and unit-tests on macOS
// (via `swift test`) AND ships unchanged inside the iOS app target.
//
// ── Optional real llama.cpp linkage ────────────────────────────────────────────
// Set QUENDERIN_LLAMA_DIR to a BUILT llama.cpp checkout (one that contains
// `include/llama.h`, `ggml/include/`, and `build/bin/libllama.dylib`) and the
// `llama` system-library target is added + linked, so `LlamaEngine.swift`'s
// `#if canImport(llama)` path actually compiles, links, and runs under
// `swift build` / `swift test`. Build that checkout once with:
//
//   cmake -S llama.cpp -B llama.cpp/build -DBUILD_SHARED_LIBS=ON -DGGML_METAL=ON \
//         -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF \
//         -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_CURL=OFF
//   cmake --build llama.cpp/build --target llama -j
//
// Then: QUENDERIN_LLAMA_DIR=/abs/path/to/llama.cpp swift test
//
// With the var UNSET the package is byte-for-byte the mock-only build that
// `main` has always shipped — no dependency, `canImport(llama)` is false, and the
// engine returns a clean `.loadFailed`. See apple/QuenderinKit/INTEGRATION.md.
let llamaDir = ProcessInfo.processInfo.environment["QUENDERIN_LLAMA_DIR"]
    .flatMap { $0.isEmpty ? nil : $0 }

// Route A (the shippable path): drop a prebuilt `llama.xcframework` under Frameworks/
// and it is linked automatically — `canImport(llama)` flips true for device + simulator
// + macOS, Metal included. Build it once with llama.cpp's `./build-xcframework.sh`
// (see INTEGRATION.md), then:
//   mkdir -p apple/QuenderinKit/Frameworks
//   cp -R build-apple/llama.xcframework apple/QuenderinKit/Frameworks/
// (`Frameworks/*.xcframework` is git-ignored — it's a large binary; ship via LFS/CI.)
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let prismFrameworkPath = "Frameworks/prism-llama.xcframework"
let runtimeName = ProcessInfo.processInfo.environment["QUENDERIN_RUNTIME"]
    ?? (FileManager.default.fileExists(atPath: packageDir + "/" + prismFrameworkPath) ? "prism" : "standard")
guard ["standard", "prism"].contains(runtimeName) else {
    fatalError("QUENDERIN_RUNTIME must be standard or prism")
}
let prismRuntime = runtimeName == "prism"
let xcframeworkRelPath = prismRuntime ? prismFrameworkPath : "Frameworks/llama.xcframework"
let hasXcframework = FileManager.default.fileExists(atPath: packageDir + "/" + xcframeworkRelPath)

// A feature flag alone cannot turn a stock binary into a ternary/Hadamard runtime.
// Source builds are verified by the same pinned-source tool used by Android;
// framework builds carry provenance written only after that source was built.
if prismRuntime {
    let root = URL(fileURLWithPath: packageDir).deletingLastPathComponent().deletingLastPathComponent()
    let lockURL = root.appendingPathComponent("shared/prism-runtime.json")
    guard let lockData = try? Data(contentsOf: lockURL),
          let lock = try? JSONSerialization.jsonObject(with: lockData) as? [String: Any] else {
        fatalError("Missing Prism runtime lock")
    }
    if let dir = llamaDir {
        let verifier = Process()
        verifier.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        verifier.arguments = ["python3", root.appendingPathComponent("scripts/prepare_prism_runtime.py").path,
                              "verify", "--source", dir]
        do { try verifier.run(); verifier.waitUntilExit() }
        catch { fatalError("Unable to verify Prism source: \(error)") }
        guard verifier.terminationStatus == 0 else { fatalError("Prism source verification failed") }
    } else if hasXcframework {
        let stampPath = packageDir + "/" + xcframeworkRelPath + "/quenderin-prism-runtime.json"
        guard let data = FileManager.default.contents(atPath: stampPath),
              let stamp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              stamp["repository"] as? String == lock["repository"] as? String,
              stamp["revision"] as? String == lock["revision"] as? String else {
            fatalError("Prism framework provenance is missing or does not match the pinned runtime")
        }
    } else {
        fatalError("Build the Prism framework or provide QUENDERIN_LLAMA_DIR; stock fallback is disabled for this profile")
    }
}

var qkDependencies: [Target.Dependency] = []
var qkSwiftSettings: [SwiftSetting] = []
var qkLinkerSettings: [LinkerSetting] = []
var optionalTargets: [Target] = []

if prismRuntime { qkSwiftSettings.append(.define("QUENDERIN_PRISM_LLAMA")) }

if hasXcframework && !(prismRuntime && llamaDir != nil) {
    // Route A — prebuilt xcframework: device/simulator/macOS, Metal GPU included.
    qkDependencies.append("llama")
    optionalTargets.append(.binaryTarget(name: "llama", path: xcframeworkRelPath))
} else if let dir = llamaDir {
    // Route C — link a local dev build of llama.cpp (headless; fastest to verify).
    qkDependencies.append("llama")
    qkSwiftSettings.append(.unsafeFlags([
        "-Xcc", "-I\(dir)/include",
        "-Xcc", "-I\(dir)/ggml/include",
    ]))
    qkLinkerSettings.append(.unsafeFlags([
        "-L\(dir)/build/bin",
        // Let the dynamic loader find libllama + its sibling libggml*.dylib at runtime.
        "-Xlinker", "-rpath", "-Xlinker", "\(dir)/build/bin",
    ]))
    optionalTargets.append(.systemLibrary(name: "llama", path: "Sources/llama"))
}

// Mirror android/jni/CMakeLists.txt: llama.cpp HEAD replaced use_mmap/use_mlock with
// enum llama_load_mode. Detect from the header the Swift adapter will actually compile
// against, then `#if QUENDERIN_LLAMA_LOAD_MODE` in LlamaEngine.swift.
func selectedLlamaHeader() -> String? {
    var candidates: [String] = []
    if let dir = llamaDir {
        candidates.append(dir + "/include/llama.h")
    }
    if hasXcframework && !(prismRuntime && llamaDir != nil) {
        let root = packageDir + "/" + xcframeworkRelPath
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            while let rel = enumerator.nextObject() as? String {
                if rel.hasSuffix("llama.h") {
                    candidates.append(root + "/" + rel)
                    break
                }
            }
        }
    }
    for path in candidates {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        return text
    }
    return nil
}

if (hasXcframework || llamaDir != nil), let header = selectedLlamaHeader() {
    if header.contains("LLAMA_LOAD_MODE_MMAP") || header.range(of: #"enum\s+llama_load_mode"#, options: .regularExpression) != nil {
        qkSwiftSettings.append(.define("QUENDERIN_LLAMA_LOAD_MODE"))
    }
    if header.range(of: #"llama_sampler_init_penalties\([^)]*n_vocab"#, options: .regularExpression) != nil {
        qkSwiftSettings.append(.define("QUENDERIN_LLAMA_PENALTIES_VOCAB"))
    }
}

let package = Package(
    name: "QuenderinKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "QuenderinKit", targets: ["QuenderinKit"]),
    ],
    targets: [
        .target(
            name: "QuenderinKit",
            dependencies: qkDependencies,
            resources: [.process("Resources")],   // brand-avatar.png (chat orbs / empty states)
            swiftSettings: qkSwiftSettings,
            linkerSettings: qkLinkerSettings
        ),
        .testTarget(name: "QuenderinKitTests", dependencies: ["QuenderinKit"]),
    ] + optionalTargets
)
