# Building and testing the Swift rewrite

`swift/` is a new, additive SwiftPM root package for the Swift 6.3 rewrite of
`wendyos-update` (see `.superpowers/sdd/` for the design and implementation
plan). It does not touch the existing Go tree (`cmd/`, `internal/`, `go.mod`,
`vendor/`) — that stays intact and still builds/tests independently (see the
`wendyos-update-linux-only-tests` project note in your Claude memory for the
Go side).

## Tests are Linux-only

Like the Go engine, the Swift package targets Linux only (no `platforms:`
clause in `Package.swift`, and later phases will use Glibc/musl-only APIs
for partition/mount/ioctl work). **Do not try to `swift build`/`swift test`
directly on macOS** — always build/test inside the Linux container flow
below.

## Prerequisites

- Docker (all build/test flows run inside a container — no host Swift
  toolchain install is required for day-to-day development).
- If you *do* want a local toolchain (e.g. for editor/LSP support), install
  Swift 6.3 via [swiftly](https://www.swift.org/swiftly/):

  ```sh
  swiftly install 6.3-snapshot   # or a specific 6.3 dev snapshot / 6.3.x release
  swiftly use 6.3-snapshot
  ```

  This is optional and only affects editor tooling — it is never what
  actually builds or runs the tests for this repo.

## Host test command (canonical)

Use `scripts/dsw` (repo root) — the canonical, already-committed wrapper
that runs `swift <args>` inside the pinned `swiftlang/swift:nightly-6.3-jammy`
container, with named Docker volumes caching `.build`, `~/.cache`, and
`~/.swiftpm` across runs so repeat builds are fast:

```sh
scripts/dsw test               # swift test
scripts/dsw build -c release   # swift build (release, native aarch64-linux-gnu)
scripts/dsw <any swift args>
```

`WOS_SWIFT_IMAGE` overrides the image if you need to pin a different
toolchain snapshot.

Verified in this container: Swift `6.3.3-dev`, target
`aarch64-unknown-linux-gnu`. `swift test` with the toolchain-bundled
`import Testing` (swift-testing) works out of the box — no external test
dependency is declared in `Package.swift`.

## Docker dev image (`swift/docker/Dockerfile`)

`scripts/dsw` is the preferred day-to-day flow (no image build step, and it
mounts the repo directly). `swift/docker/Dockerfile` is provided as an
alternative for CI or any environment that wants a single pinned, buildable
image instead — and it pre-bakes the Static Linux SDK (see below) so a
container from it can immediately run the static musl cross build with no
extra setup:

```sh
docker build -t wos-swift swift/docker
docker run --rm -v "$PWD/swift:/w" -w /w wos-swift swift test
```

Verified: `docker build -t wos-swift swift/docker` completes (downloads and
installs the Static Linux SDK during the build), and the `swift test` run
above passes with the same output as `scripts/dsw test`.

## Static-musl cross build

### SDK install

The Static Linux SDK (Musl) lets you cross-link a fully static, dependency-free
Linux binary. It must be installed once per toolchain (`swift/docker/Dockerfile`
does this automatically; when using `scripts/dsw` directly instead, install it
by hand first — SwiftPM's SDK registry lives under `~/.swiftpm` inside the
container, so if you want it to persist across `scripts/dsw` invocations, add
a `-v <volume>:/root/.swiftpm` mount to a one-off `docker run` similar to
`scripts/dsw`).

**Verified working SDK identifier for the `swiftlang/swift:nightly-6.3-jammy`
(Swift `6.3.3-dev`) toolchain used by `scripts/dsw`:**

```sh
swift sdk install \
  https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
  --checksum 87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b
```

This installs as SDK id `swift-6.3.3-RELEASE_static-linux-0.1.0` and exposes
the `--swift-sdk` targets used below (`swift sdk list` to confirm). The
6.3.3-RELEASE static SDK bundle is compatible with the `6.3.3-dev` nightly
toolchain image despite the version strings not matching exactly — this was
verified end-to-end (SDK install + cross build + static-link check) as part
of Task 0.2 of the rewrite; see `.superpowers/sdd/task-0.2-report.md` for
the full transcript. If a future toolchain bump breaks compatibility, check
<https://www.swift.org/documentation/articles/static-linux-getting-started.html>
for the current recommended URL/checksum pair, or fall back to downloading
the bundle out-of-band (`curl -LO <url>`, verify the checksum yourself, then
`swift sdk install <local-file> --checksum <checksum>`) if `swift sdk
install`'s own HTTPS fetch is ever blocked in a given environment.

### Cross build

```sh
swift build --swift-sdk aarch64-swift-linux-musl -c release   # Jetson/Pi (arm64)
swift build --swift-sdk x86_64-swift-linux-musl  -c release   # x86_64 targets, if ever needed
```

Verified: `swift build --swift-sdk aarch64-swift-linux-musl -c release`
succeeds against the current package skeleton and produces
`.build/aarch64-swift-linux-musl/release/wendyos-update`; `ldd` on that
binary reports `not a dynamic executable` — i.e. it is fully statically
linked (Swift runtime, Foundation, and libc) with no `.so` dependencies, in
contrast to the native debug/test build (`.build/aarch64-unknown-linux-gnu/debug/wendyos-update`),
which is dynamically linked.

### `WOS_STATIC_LINK` (Package.swift opt-in)

`Package.swift` reads the `WOS_STATIC_LINK` environment variable. When set
(to any value), it adds `-static-stdlib -static-executable` to the
`WendyUpdate` executable target's linker flags, but **only** for `-c
release` builds on Linux — `swift test` / debug builds are never affected.

```sh
WOS_STATIC_LINK=1 swift build --swift-sdk aarch64-swift-linux-musl -c release
```

This is a belt-and-suspenders pin, not a requirement: the Static Linux SDK
cross build above already links fully statically **by default**, with no
extra flags. `WOS_STATIC_LINK` exists to make that intent explicit in the
build invocation and to guard against the SDK's own default ever changing
upstream.

**Do not set `WOS_STATIC_LINK` for a plain native (glibc) `-c release`
build** (i.e. without `--swift-sdk aarch64-swift-linux-musl`). This was
tried and fails: the base `swiftlang/swift` toolchain image does not ship
static ICU archives compatible with Foundation's `-static-stdlib` mode, so
the link step fails with errors like:

```
undefined reference to 'swift_unumf_openResult'
undefined reference to 'swift_udat_open'
...
relocation refers to local symbol "" [1], which is defined in a discarded section
```

Left unset, a plain `swift build -c release` (no SDK) still works and
produces a normal dynamically-linked binary — this is unchanged from
before Task 0.2 and is what CI/dev should use whenever the static-musl
cross build isn't specifically what's wanted.

## Summary of verified commands

| Command | Result |
|---|---|
| `scripts/dsw test` | PASS — 1 test, `aarch64-unknown-linux-gnu`, dynamic |
| `scripts/dsw build -c release` | PASS — dynamic release binary (native glibc) |
| `docker build -t wos-swift swift/docker && docker run --rm -v "$PWD/swift:/w" -w /w wos-swift swift test` | PASS |
| `swift sdk install <static-sdk-url> --checksum <...>` | PASS — installs `swift-6.3.3-RELEASE_static-linux-0.1.0` |
| `swift build --swift-sdk aarch64-swift-linux-musl -c release` | PASS — fully static binary (`ldd` → not a dynamic executable) |
| `WOS_STATIC_LINK=1 swift build --swift-sdk aarch64-swift-linux-musl -c release` | PASS — same static result |
| `WOS_STATIC_LINK=1 swift build -c release` (no SDK) | **FAILS by design** — documented above, do not use |
