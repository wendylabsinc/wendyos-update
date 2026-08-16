// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Zstd",
    products: [
        .library(name: "Zstd", targets: ["Zstd"])
    ],
    targets: [
        // zstd itself is vendored (Sources/CZstd/zstd.c, the official
        // single-file amalgamation — see Sources/CZstd/VENDORED.md) and
        // compiled directly into this target rather than linked from a
        // system libzstd: the static-musl cross build's SDK sysroot
        // doesn't ship zstd.h or libzstd at all. zlib stays a system
        // dependency (linked via `z` below) since the musl Static Linux
        // SDK does ship zlib.h + a static libz.
        .target(
            name: "CZstd",
            cSettings: [
                // zstd's x86/x64 inline asm decompression fast path is
                // already guarded upstream to compile out on non-x86
                // targets, but disabling it explicitly sidesteps any
                // cross-compilation surprises on aarch64-musl, where the
                // sysroot's toolchain/assembler support is the least
                // battle-tested part of this build.
                .define("ZSTD_DISABLE_ASM")
            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
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
