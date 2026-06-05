// swift-tools-version: 6.0
import PackageDescription

// QuenderinKit — the portable "brain" of Quenderin's offline-autonomy vision.
// Pure Foundation, zero UI dependencies, so it compiles and unit-tests on macOS
// (via `swift test`) AND ships unchanged inside the iOS app target.
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
        .target(name: "QuenderinKit"),
        .testTarget(name: "QuenderinKitTests", dependencies: ["QuenderinKit"]),
    ]
)
