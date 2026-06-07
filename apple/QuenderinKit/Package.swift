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

var qkDependencies: [Target.Dependency] = []
var qkSwiftSettings: [SwiftSetting] = []
var qkLinkerSettings: [LinkerSetting] = []
var optionalTargets: [Target] = []

if let dir = llamaDir {
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
            swiftSettings: qkSwiftSettings,
            linkerSettings: qkLinkerSettings
        ),
        .testTarget(name: "QuenderinKitTests", dependencies: ["QuenderinKit"]),
    ] + optionalTargets
)
