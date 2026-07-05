// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Zstd",
    products: [
        .library(name: "Zstd", targets: ["Zstd"])
    ],
    targets: [
        .systemLibrary(
            name: "CZstd",
            pkgConfig: nil,
            providers: [.apt(["libzstd-dev", "zlib1g-dev"])]
        ),
        .target(
            name: "Zstd",
            dependencies: ["CZstd"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZstdTests",
            dependencies: ["Zstd"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
