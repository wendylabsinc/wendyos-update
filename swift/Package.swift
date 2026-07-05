// swift-tools-version:6.1
import PackageDescription
import Foundation

// Set WOS_STATIC_LINK=1 to pass `-static-stdlib -static-executable` into a
// `-c release` build so the produced binary has no shared Swift-runtime
// (or libc) dependency at deploy time.
//
// This is meaningful only when combined with the Static Linux SDK cross
// build documented in docs/swift-build.md:
//
//   swift build --swift-sdk aarch64-swift-linux-musl -c release
//
// which already links fully statically by default — WOS_STATIC_LINK just
// makes that intent explicit and pins it down if the SDK's own default
// ever changes. Do NOT set WOS_STATIC_LINK for a plain native (glibc)
// release build: the base `swiftlang/swift` toolchain image does not ship
// static ICU archives compatible with Foundation's static-stdlib mode, so
// the link step fails with `undefined reference to swift_unumf_*` (and
// similar) errors. Left unset (the default), `swift test` and a plain
// `swift build -c release` are unaffected.
let wantsStaticLink = ProcessInfo.processInfo.environment["WOS_STATIC_LINK"] != nil

let package = Package(
    name: "wendyos-update",
    products: [
        .executable(name: "wendyos-update", targets: ["WendyUpdate"])
    ],
    dependencies: [
        // Pinned to an exact beta tag (rather than a `from:`/`upToNextMinor`
        // range) because SwiftPM version ranges don't reliably resolve
        // pre-release tags — `exact:` sidesteps that entirely and pins
        // PlatformIO's `RealCommandRunner` to the API this was built
        // against.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.0-beta.1"),
        // swift-subprocess's own `Executable`/`Environment` APIs take a
        // `FilePath` from this package's `SystemPackage` product (it
        // re-exports Apple's toolchain-provided `System` module where that
        // exists, and provides its own implementation where it doesn't) —
        // depended on directly here so PlatformIO can construct `FilePath`
        // values without guessing which module the toolchain provides.
        .package(url: "https://github.com/apple/swift-system.git", from: "1.5.0"),
        // JSON decode/encode for the Model target. IkigaJSON's `JSONObject`
        // is used directly (order-preserving parse + ordered-insertion
        // encode) instead of Foundation's Codable/JSONDecoder/JSONEncoder —
        // see swift/Sources/Model/Model.swift for why.
        .package(url: "https://github.com/orlandos-nl/swift-json.git", from: "2.5.0"),
        // ustar-format tar streaming reader/writer for `.wendy` artifacts —
        // used by the Artifact target's reader (Task 3.2) to walk the
        // manifest.json/payload members without buffering the whole
        // archive.
        .package(path: "Packages/Tar"),
        // SHA-256 for the Artifact target's reader: tees the (still
        // compressed) payload bytes through an incremental digest and
        // verifies it against `manifest.payload.compressed_sha256`.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // zstd/gzip streaming (de)compression for the Artifact target's
        // writer (Task 3.4): compresses a rootfs image into the `.wendy`
        // payload member. The wos-swift test image already has
        // libzstd-dev/zlib1g-dev installed (see CZstd's `providers`).
        .package(path: "Packages/Zstd"),
    ],
    targets: [
        .executableTarget(
            name: "WendyUpdate",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: wantsStaticLink
                ? [
                    .unsafeFlags(
                        ["-static-stdlib", "-static-executable"],
                        .when(platforms: [.linux], configuration: .release)
                    )
                ]
                : []
        ),
        .testTarget(
            name: "WendyUpdateTests",
            dependencies: ["WendyUpdate"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .systemLibrary(
            name: "CLinuxSys"
        ),
        .target(
            name: "LinuxSys",
            dependencies: ["CLinuxSys"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LinuxSysTests",
            dependencies: ["LinuxSys"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PlatformIO",
            dependencies: [
                "LinuxSys",
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PlatformIOTesting",
            dependencies: ["PlatformIO"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PlatformIOTests",
            dependencies: ["PlatformIO", "PlatformIOTesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Model",
            dependencies: [
                .product(name: "IkigaJSON", package: "swift-json")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ModelTests",
            dependencies: ["Model"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CLIError",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Artifact",
            dependencies: [
                "Model", "CLIError", "LinuxSys",
                .product(name: "Tar", package: "Tar"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Zstd", package: "Zstd"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ArtifactTests",
            dependencies: ["Artifact"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "BlockDev",
            dependencies: [
                "PlatformIO", "LinuxSys", "CLIError",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Zstd", package: "Zstd"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BlockDevTests",
            dependencies: ["BlockDev", "PlatformIO", "PlatformIOTesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Connector",
            dependencies: ["CLIError"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConnectorTests",
            dependencies: ["Connector"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Engine",
            dependencies: ["Connector", "Model", "PlatformIO", "CLIError"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EngineTests",
            dependencies: ["Engine", "Model", "PlatformIO", "PlatformIOTesting", "Connector"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
