# Dev/CI image for the wendyos-update Swift 6.3 rewrite.
#
# This uses the same base image as scripts/dsw (the canonical host
# build/test runner — see ../../scripts/dsw and ../../docs/swift-build.md).
# Prefer `scripts/dsw test` for day-to-day development: it mounts the repo
# directly and caches `.build`/SwiftPM state in named volumes, so it needs
# no image build step and no rebuild when only source files change. This
# Dockerfile exists for:
#
#   - CI or other environments that want a single pinned, buildable image
#     instead of scripts/dsw's docker-run-based flow;
#   - pre-baking the Static Linux SDK (Musl) so the image can immediately
#     run the static cross build documented in ../../docs/swift-build.md.
#
# Build + run (mirrors scripts/dsw test, but via a built image):
#
#   docker build -t wos-swift swift/docker
#   docker run --rm -v "$PWD/swift:/w" -w /w wos-swift swift test
#
# Cross build to a fully static aarch64 binary:
#
#   docker run --rm -v "$PWD/swift:/w" -w /w wos-swift \
#     swift build --swift-sdk aarch64-swift-linux-musl -c release
FROM swiftlang/swift:nightly-6.3-jammy

# zstd itself is vendored into the Zstd package's CZstd target (compiled
# from source — see swift/Packages/Zstd/Sources/CZstd/VENDORED.md), so no
# system libzstd-dev is needed here. zlib1g-dev is already present in the
# base image (needed to build Swift itself) but is listed explicitly here
# too since the Zstd package links against it directly via CZstd's module
# map.
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Static Linux SDK (Musl), used for `swift build --swift-sdk
# aarch64-swift-linux-musl -c release`. The SDK version must match (or be
# compatible with) the toolchain above; see docs/swift-build.md for how
# this identifier/checksum pair was found and verified against this same
# base image.
ARG STATIC_SDK_URL=https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
ARG STATIC_SDK_CHECKSUM=87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b

RUN swift sdk install "${STATIC_SDK_URL}" --checksum "${STATIC_SDK_CHECKSUM}"

WORKDIR /w

CMD ["swift", "test"]
