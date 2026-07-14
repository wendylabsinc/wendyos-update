// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tar",
    products: [
        .library(name: "Tar", targets: ["Tar"])
    ],
    targets: [
        .target(
            name: "Tar",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TarTests",
            dependencies: ["Tar"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
