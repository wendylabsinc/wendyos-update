// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "wendyos-update",
    products: [
        .executable(name: "wendyos-update", targets: ["WendyUpdate"])
    ],
    targets: [
        .executableTarget(
            name: "WendyUpdate",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WendyUpdateTests",
            dependencies: ["WendyUpdate"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
