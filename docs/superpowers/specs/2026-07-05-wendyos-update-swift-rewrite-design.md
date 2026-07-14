# wendyos-update — Swift 6.3 rewrite (design)

Date: 2026-07-05
Status: proposed (draft-PR target)

## Goal

Reimplement `wendyos-update` — the generic A/B OTA tool for WendyOS — in
Swift 6.3, at **full behavioral parity** with the current Go implementation,
delivered as a **draft PR** that is testable on a plain Linux host (no Jetson
required). Reusable, board-agnostic pieces are factored into standalone Swift
packages for the wider WendyOS/Swift ecosystem.

The frozen v1 contracts are **unchanged** and remain the source of truth:
`docs/cli-contract.md`, `docs/manifest-schema.md`, `docs/state-schema.md`,
`docs/connector-architecture.md`. The rewrite must reproduce them exactly
(verbs, exit codes, JSON-lines progress, `status --json` shape, state-file
ordering, connector boundary).

## Non-goals

- No contract changes. This is a like-for-like port, not a v2.
- No new boards. Parity means the same two connectors: `tegrauefi` and
  `ubootenv`.
- The Go tree is **not deleted** in this PR. Swift lands alongside it and
  becomes authoritative only after hardware parity is verified.

## Runtime decision: full Swift, statically linked against MUSL

Literal Embedded Swift was considered and **rejected**: `install <url>`
needs an HTTP+TLS client, and the chosen client (`async-http-client`) pulls
in SwiftNIO, which requires the full Swift runtime. Instead:

- Build with the **Swift Static Linux SDK (Musl)**:
  `swift build --swift-sdk aarch64-swift-linux-musl` (and an `x86_64`
  variant for host CI). Output is a single fully-static binary with no
  runtime dependencies on the device — the deployment property that made
  Embedded attractive, without giving up Foundation/NIO/crypto.
- Swift 6 language mode, strict concurrency. The tool is essentially a
  synchronous CLI; the only async surface is the HTTP download, driven from
  an `@main` entry via a top-level `await`.

Toolchain requirement (documented in the build section): a Swift 6.3
toolchain plus the matching Static Linux SDK installed
(`swift sdk install`).

## Dependencies

External (all Linux-vetted; SSWG where noted):

| Package | Role | Notes |
|---|---|---|
| `apple/swift-argument-parser` | CLI verbs + flags | replaces the hand-rolled `os.Args` switch |
| `swift-server/async-http-client` | `install <url>` streaming download | HTTP/1.1+2, TLS via NIO-SSL/BoringSSL; builds under static-musl |
| `apple/swift-crypto` | rolling SHA-256 | `import Crypto`, `SHA256` incremental |
| `orlandos-nl/swift-json` (IkigaJSON) | JSON encode/decode | zero-copy, non-Codable; deterministic key order for `status --json` |
| `wendylabsinc/swift-json-schema` | build-plugin: schema → models | `SwiftJSON` trait emits IkigaJSON `JSONObjectView` decoders, bypassing Codable |
| `swiftlang/swift-subprocess` | run `nvbootctrl`/`mount`/`lsblk`/`fw_printenv` etc. | modern SSWG-track subprocess; Linux-first |
| `apple/swift-log` | structured logging | fronted by a custom journal/TTY/plain `LogHandler` |

New in-repo packages (local SwiftPM packages now; extractable to their own
repos later — the "ecosystem split"):

| Package | Role | Why split |
|---|---|---|
| `Tar` | streaming ustar reader + writer | no blessed Swift tar library exists; broadly reusable |
| `Zstd` | thin Swift API over system `libzstd` + `zlib` (C interop) | reusable compression seam; keeps `BlockDev` clean |
| `WendyLogHandler` *(nice-to-have)* | journald-`<N>`/TTY-bar/plain `swift-log` backend | reusable across WendyOS Swift CLIs |

Internal (not published): a small `LinuxSys` module wrapping the raw
syscalls Foundation won't do — `open(O_WRONLY)` without `O_CREATE`,
`fsync(fd)`, `lseek(SEEK_END)` for block-device capacity, and `ioctl` for
efivar immutable-flag toggling (`FS_IOC_GETFLAGS`/`SETFLAGS`) and TTY
detection (`isatty`/`TCGETS`).

## Package / module map (Go → Swift)

Each Swift module has one clear purpose and a faked-at-the-seam boundary so
it is testable in isolation.

| Go source | Swift target | Responsibility |
|---|---|---|
| `internal/artifact/{manifest,reader,writer,sparse}.go` | `Artifact` | `.wendy` parse/validate (manifest-first streaming read), pack/write, sparse-file expansion; uses `Tar` + `Zstd` + `Crypto` |
| `internal/blockdev/blockdev.go` | `BlockDev` | decompress + stream payload to a block device with rolling SHA-256; device capacity; `fsync` |
| `internal/engine/*.go` | `Engine` | install/commit/rollback/switch/status/mark-good/verify-boot sequencing; `state.json`/`installed.json` atomic writes; policy gates; hook runner |
| `internal/connector/{connector,registry}.go` | `Connector` | `Connector` protocol, `Slot`, optional-capability protocols, name registry + `Select` |
| `internal/connector/tegrauefi/*.go` | `TegraUEFI` | `nvbootctrl` + efivars + capsule/ESRT; `Detect` |
| `internal/connector/ubootenv/*.go` | `UBootEnv` | `fw_printenv`/`fw_setenv` trial-boot A/B; `Detect` |
| `internal/log/log.go` | `Logging` (+ `WendyLogHandler`) | swift-log handler + progress reporter (TTY bar / journal lines / plain) |
| `cmd/wendyos-update/{main,pack}.go` | `wendyos-update` (executable) | argument-parser verbs, config load, HTTP download, exit-code mapping, `pack` |

## Key design points

### Connector polymorphism
`protocol Connector: AnyObject` with `final class` connectors; the engine
holds `any Connector` (a class-existential). Optional capabilities
(`BootConfirmer`, `InstallPreflighter`) are separate protocols the engine
probes with `as?` — the direct analog of Go's interface assertions. The
registry maps name → `(factory, detect)`; `Select(explicit:)` reproduces the
exact resolution order and error messages (explicit → single auto-detect →
hard error; ambiguous is an error — never guess on an OTA path).

### Error model and exit codes
No `any Error` juggling. Each module defines a concrete `enum` error with
typed throws where it clarifies flow. The CLI maps them to the frozen exit
codes:

| Exit | Go | Swift |
|---|---|---|
| 2 | `ErrNothingToCommit` | `CommitError.nothingToCommit` |
| 3 | `RejectError` | `ArtifactRejected` |
| 4 | `PlatformVerifyError` / health `HookError` | `VerifyFailed` / `HookError(.health)` |
| 1 | everything else | default |

### JSON via schema-generated IkigaJSON
`manifest.json`, `state.json`, `installed.json`, `config.json`, and the
`status --json` output get JSON Schema files under `Schemas/`. The
`swift-json-schema` plugin generates the model structs with the `SwiftJSON`
trait so decode uses IkigaJSON's zero-copy `JSONObjectView` path (no Codable
reflection). Encoding uses IkigaJSON with **stable key order** so
`status --json` and state files are byte-reproducible for tests and
back-compat. Manifest size is bounded (4 MiB, matching `maxManifestSize`).

### Platform I/O seams (testability)
Every side-effecting boundary is a protocol injected into the type that
uses it, mirroring how the Go `Engine` takes all paths as fields and fakes
the `Connector`:

- `FileStore` — read/write/rename/mkdir/remove/stat (real: `LinuxSys`+FS).
- `CommandRunner` — run a subprocess, capture stdout/exit (real:
  `swift-subprocess`).
- `BlockTarget` — open/write/fsync/capacity of a device path.
- `Clock` / `EnvReader` — time + environment (for deterministic state
  timestamps and mode detection).

Connectors depend only on `CommandRunner` + `FileStore`, so `TegraUEFI` and
`UBootEnv` logic is unit-tested with recorded command fixtures — the same
approach as `tegrauefi_test.go`/`ubootenv_test.go`.

### Logging & progress
`Logging` installs a `swift-log` `LogHandler` that reproduces
`internal/log`: `$JOURNAL_STREAM` → journal mode (`<3|4|6|7>` sd-daemon
severity prefixes, `wendyos-update:` tag), TTY → colored lines + a
carriage-return progress bar, else plain timestamped lines. Progress is a
separate `ProgressReporter` (bar on TTY only; no-op otherwise) so log lines
and the bar never corrupt each other. stdout stays the machine-only JSON
channel; the high-frequency progress JSON is suppressed when stdout is a
TTY, exactly as today.

### install `<url>` download
`async-http-client` streams the response body; its `AsyncSequence` of
byte chunks feeds the same artifact/blockdev pipeline used for a local
file. Per-stage timeouts mirror the Go client (dial/TLS/response-header
bounded; no overall timeout for the multi-GB body). Ctrl-C / SIGTERM
cancels the in-flight request and aborts a partial write.

## Build, packaging, testing

- **SwiftPM** root package with the modules above + local packages; product
  is the `wendyos-update` executable. `Zstd` links system `libzstd`/`zlib`
  via a C system-library target.
- **Static musl** binary via the Static Linux SDK; `Package.swift` sets the
  linker flags for a fully static executable.
- **Yocto**: a recipe replacing the `go.bbclass` recipe in meta-edgeos —
  builds via the Swift toolchain + Static SDK and installs the static
  binary; the existing `systemd/` units ship unchanged. (Recipe detail is
  meta-edgeos work, tracked separately.)
- **Docker/dev**: a Swift 6.3 toolchain image for host `swift build` +
  `swift test`, mirroring the current Go-in-docker workflow (tests are
  Linux-only).
- **Testing**: standard `swift test` (swift-testing) on the host. All
  platform I/O is faked at the seams, so `Artifact` round-trips, `Engine`
  state-machine ordering, `pack` self-verify, `status` rendering, `BlockDev`
  writes-to-a-regular-file, both connectors' command logic, and `Tar`/`Zstd`
  are all covered without hardware. Test cases are ported 1:1 from the Go
  `_test.go` files.

## Parity checklist (must all hold before Go is retired)

- [ ] Verbs: `install`, `commit`, `rollback`, `switch`, `status [--json]
      [--verbose]`, `mark-good`, `pack`, `verify-boot`, `version`.
- [ ] Exit codes 0/1/2/3/4 mapped identically.
- [ ] `status --json` object shape byte-compatible (slots[]/system[]/
      pending/diagnostics; empty fields omitted; ordered system[]).
- [ ] Progress JSON lines on stdout; suppressed on TTY.
- [ ] `state.json` phase ordering + atomic rename + `installed.json` cap 10.
- [ ] Hook phases + env vars + first-non-zero-exit semantics.
- [ ] Connector boundary: no connector type leaks into `Engine`; auto-detect
      + explicit-override resolution and messages.
- [ ] Tegra: `nvbootctrl` slot switch, efivar `RootfsStatusSlot*` reset,
      capsule/OsIndications staging, ESRT verify cascade, preflight refuse
      when A/B redundancy not armed, per-boot confirm.
- [ ] U-Boot: `fw_setenv` trial-boot arming + fallback detection.
- [ ] `.wendy` format: tar (manifest-first), zstd/gzip/none, dual digests.

## Risks

- **Static-musl + BoringSSL (async-http-client)**: known-good with the
  Static Linux SDK, but must be validated early in the build task; fallback
  is a `curl` subprocess for the URL case (already have `CommandRunner`).
- **`swift-json-schema` maturity**: silently ignores some keywords; our
  schemas stay within the supported subset, and encode paths use IkigaJSON
  directly where the plugin is insufficient.
- **Foundation-on-musl gaps**: mitigated by keeping raw file/device ops in
  `LinuxSys` rather than Foundation.
- **Reproducing `status --json` byte-for-byte**: requires deterministic key
  ordering in the encoder — verified by golden-file tests.

## PR delivery plan (draft)

Branch `feature/swift-rewrite` off `feature/draft`. Lands:
1. SwiftPM package + local `Tar`/`Zstd`(/`WendyLogHandler`) packages.
2. Ported modules with unit tests (green under `swift test`).
3. This design doc + a Go→Swift file-mapping note + build/dev docs.
4. Draft PR with a "parity checklist" body and an explicit "not yet
   validated on Jetson hardware" caveat.

Go tree stays; Swift is additive until hardware parity is signed off.
