// swift-tools-version:6.0
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
    ]
)
