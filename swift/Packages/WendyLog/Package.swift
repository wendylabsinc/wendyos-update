// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WendyLog",
    products: [
        .library(name: "WendyLog", targets: ["WendyLog"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "WendyLog",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WendyLogTests",
            dependencies: ["WendyLog"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
