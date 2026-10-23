// swift-tools-version: 6.4

// Swift bindings of the Rust core. `make apple-core` produces everything
// under Generated/; never edit it by hand.

import PackageDescription

let package = Package(
    name: "LeafCore",
    platforms: [.iOS(.v26), .macOS(.v27)],
    products: [.library(name: "LeafCore", targets: ["LeafCore"])],
    targets: [
        .binaryTarget(name: "LeafCoreFFI", path: "Generated/LeafCoreFFI.xcframework"),
        .target(name: "LeafCore", dependencies: ["LeafCoreFFI"], path: "Generated/Swift"),
        .testTarget(name: "LeafCoreTests", dependencies: ["LeafCore"]),
    ]
)
