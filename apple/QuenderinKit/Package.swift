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
// ci_post_clone persists this profile before Xcode resolves the package. Xcode's
// package subprocess must not silently become a stock/mock build if it loses the
// workflow environment. The archive guard separately requires the explicit env.
let prismRelease = FileManager.default.fileExists(atPath: packageDir + "/.quenderin-prism-release")
let runtimeName = ProcessInfo.processInfo.environment["QUENDERIN_RUNTIME"]
    ?? (prismRelease || FileManager.default.fileExists(atPath: packageDir + "/" + prismFrameworkPath) ? "prism" : "standard")
guard ["standard", "prism"].contains(runtimeName) else {
    fatalError("QUENDERIN_RUNTIME must be standard or prism")
}
let prismRuntime = runtimeName == "prism"
let xcframeworkRelPath = prismRuntime ? prismFrameworkPath : "Frameworks/llama.xcframework"
let hasXcframework = FileManager.default.fileExists(atPath: packageDir + "/" + xcframeworkRelPath)
let diffusionFrameworkPath = "Frameworks/QuenderinDiffusion.xcframework"
let hasDiffusionFramework = FileManager.default.fileExists(atPath: packageDir + "/" + diffusionFrameworkPath)
if prismRelease && !hasDiffusionFramework {
    fatalError("Release profile requires the verified local image runtime framework")
}
if hasDiffusionFramework {
    let root = URL(fileURLWithPath: packageDir).deletingLastPathComponent().deletingLastPathComponent()
    let verifier = Process()
    verifier.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    verifier.arguments = ["python3", root.appendingPathComponent("scripts/verify_diffusion_apple_runtime.py").path,
                          "verify", "--framework", packageDir + "/" + diffusionFrameworkPath]
    do { try verifier.run(); verifier.waitUntilExit() }
    catch { fatalError("Unable to verify image runtime: \(error)") }
    guard verifier.terminationStatus == 0 else { fatalError("Image runtime framework verification failed") }
}
if prismRelease && (!prismRuntime || llamaDir != nil) {
    fatalError("Release profile requires the verified Prism xcframework; stock/source fallback is disabled")
}

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
              let sourcePatch = lock["sourcePatch"] as? [String: Any],
              let weeklyPatch = lock["weeklyTextPatch"] as? [String: Any],
              let beamPatch = lock["beamPatch"] as? [String: Any],
              let visionPatch = lock["visionPatch"] as? [String: Any],
              let granitePatch = lock["graniteConverterPatch"] as? [String: Any],
              stamp["repository"] as? String == lock["repository"] as? String,
              stamp["revision"] as? String == lock["revision"] as? String,
              stamp["sourcePatchId"] as? String == sourcePatch["id"] as? String,
              stamp["sourcePatchSha256"] as? String == sourcePatch["sha256"] as? String,
              stamp["museSparkABI"] as? Int == 1,
              sourcePatch["museSparkABI"] as? Int == 1,
              stamp["weeklyTextPatchId"] as? String == weeklyPatch["id"] as? String,
              stamp["weeklyTextPatchSha256"] as? String == weeklyPatch["sha256"] as? String,
              stamp["weeklyTextABI"] as? Int == 1,
              weeklyPatch["weeklyTextABI"] as? Int == 1,
              stamp["beamPatchId"] as? String == beamPatch["id"] as? String,
              stamp["beamPatchSha256"] as? String == beamPatch["sha256"] as? String,
              stamp["beamABI"] as? Int == 1,
              stamp["visionPatchId"] as? String == visionPatch["id"] as? String,
              stamp["visionPatchSha256"] as? String == visionPatch["sha256"] as? String,
              stamp["visionABI"] as? Int == 1,
              stamp["graniteConverterPatchId"] as? String == granitePatch["id"] as? String,
              stamp["graniteConverterPatchSha256"] as? String == granitePatch["sha256"] as? String else {
            fatalError("Prism framework provenance is missing or does not match the pinned runtime")
        }
        let verifier = Process()
        verifier.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        verifier.arguments = ["python3", root.appendingPathComponent("scripts/verify_prism_apple_runtime.py").path,
                              "verify-framework", "--framework", packageDir + "/" + xcframeworkRelPath]
        do { try verifier.run(); verifier.waitUntilExit() }
        catch { fatalError("Unable to verify Prism framework: \(error)") }
        guard verifier.terminationStatus == 0 else { fatalError("Prism framework verification failed") }
    } else {
        fatalError("Build the Prism framework or provide QUENDERIN_LLAMA_DIR; stock fallback is disabled for this profile")
    }
}

var qkDependencies: [Target.Dependency] = []
var qkSwiftSettings: [SwiftSetting] = []
var qkLinkerSettings: [LinkerSetting] = []
var optionalTargets: [Target] = []
// Real locked UniFFI SDK: generated Swift wrapper plus the matching static FFI
// XCFramework. A partial/stale artifact must fail before dependency resolution.
let remoteSDK = "build/RemoteCryptoSDK"
let hasRemoteSDK = FileManager.default.fileExists(atPath: packageDir + "/" + remoteSDK)
let remoteReleaseMarker = packageDir + "/build/.quenderin-remote-crypto-release"
let hasRemoteReleaseMarker = FileManager.default.fileExists(atPath: remoteReleaseMarker)
// Persist the requirement before package resolution: an environment lost by a
// package subprocess must never turn a release into the unavailable adapter.
if prismRelease && !hasRemoteReleaseMarker {
    fatalError("Release profile requires the verified native remote crypto marker")
}
if (prismRelease || hasRemoteReleaseMarker || ProcessInfo.processInfo.environment["QUENDERIN_REQUIRE_REMOTE_CRYPTO"] == "1") && !hasRemoteSDK {
    fatalError("Build the verified native remote crypto SDK before compiling this profile")
}
if hasRemoteSDK {
    let root = URL(fileURLWithPath: packageDir).deletingLastPathComponent().deletingLastPathComponent()
    let verifier = Process()
    verifier.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    let output = Pipe()
    verifier.standardOutput = output
    verifier.arguments = ["python3", "-B", root.appendingPathComponent("native/remote-crypto/tools/native_sdk.py").path,
                          "apple-link-settings", "--sdk", packageDir + "/" + remoteSDK]
    do { try verifier.run(); verifier.waitUntilExit() }
    catch { fatalError("Unable to verify remote crypto SDK") }
    guard verifier.terminationStatus == 0 else { fatalError("Remote crypto SDK provenance verification failed") }
    guard let linkFlags = try? JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String],
          !linkFlags.isEmpty else { fatalError("Missing verified remote crypto link contract") }
    // Distribution exports must not hide Swift APIs when Xcode turns the
    // automatic package product into a dynamic framework for Debug tests.
    qkLinkerSettings.append(.unsafeFlags(linkFlags, .when(configuration: .release)))
    optionalTargets.append(.binaryTarget(name: "QuenderinRemoteCryptoFFI", path: remoteSDK + "/QuenderinRemoteCryptoFFI.xcframework"))
    optionalTargets.append(.target(name: "QuenderinRemoteCrypto", dependencies: ["QuenderinRemoteCryptoFFI"],
                                   path: remoteSDK + "/Sources/QuenderinRemoteCrypto"))
    qkDependencies.append("QuenderinRemoteCrypto")
}
if hasDiffusionFramework {
    qkDependencies.append("QuenderinDiffusion")
    optionalTargets.append(.binaryTarget(name: "QuenderinDiffusion", path: diffusionFrameworkPath))
}

// Portable MAX boundary. The staged C sources are byte-verified by
// scripts/stage_apple_max_model.py; no vendor runner is linked.
qkDependencies.append("CMaxModel")
optionalTargets.append(.target(name: "CMaxModel", path: "Sources/CMaxModel", publicHeadersPath: "include"))

if prismRuntime {
    qkSwiftSettings.append(.define("QUENDERIN_PRISM_LLAMA"))
    // Reaching this point requires the exact Muse source patch or sealed framework.
    qkSwiftSettings.append(.define("QUENDERIN_MUSE_LLAMA"))
    qkSwiftSettings.append(.define("QUENDERIN_WEEKLY_TEXT_LLAMA"))
    qkSwiftSettings.append(.define("QUENDERIN_BEAM_LLAMA"))
    // The sealed framework verifier checks every slice's vision header and exports.
    // Generic source-only llama builds have no linked bridge and remain unavailable.
    if hasXcframework && llamaDir == nil {
        qkSwiftSettings.append(.define("QUENDERIN_VISION_LLAMA"))
    }
}

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
    // The adapter calls these C APIs directly; macOS does not re-export them
    // through libllama's transitive dependencies.
    qkLinkerSettings += [.linkedLibrary("ggml-base"), .linkedLibrary("ggml-cpu")]
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
        // Pinned upstream xcframework deployment minima.
        .iOS("16.4"),
        .macOS("13.3"),
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
        .testTarget(name: "QuenderinKitTests", dependencies: [.target(name: "QuenderinKit")] + qkDependencies,
                    swiftSettings: qkSwiftSettings, linkerSettings: qkLinkerSettings),
    ] + optionalTargets
)
