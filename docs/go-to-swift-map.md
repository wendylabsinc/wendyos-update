# Go → Swift file map

`swift/` is a full-parity Swift 6.3 rewrite of the Go `wendyos-update` tree.
This doc maps every non-test Go source file to its Swift equivalent(s), lists
the Swift-only support layers that have no direct Go counterpart, and gives
an honest, per-item parity checklist.

The Go side was enumerated with:

```sh
git ls-files 'cmd/*.go' 'internal/**/*.go' | grep -v _test
```

The Swift side with:

```sh
git ls-files 'swift/Sources/**/*.swift'
git ls-files 'swift/Packages/**/*.swift'
```

Both trees are still in the repo, unmodified by this doc. The Go tree
(`cmd/`, `internal/`) remains authoritative; see `README.md` and
`docs/swift-build.md`.

## Module-by-module map

### CLI entry point (`cmd/wendyos-update/`)

| Go | Swift |
|---|---|
| `cmd/wendyos-update/main.go` — verb dispatch (`os.Args[1]` switch), exit-code mapping, connector registration imports, logging bootstrap | `swift/Sources/WendyUpdate/Command.swift` (verb dispatch via swift-argument-parser subcommands), `swift/Sources/WendyUpdate/ExitCode.swift` (exit-code mapping), `swift/Sources/WendyUpdate/Runtime.swift` (connector registration + logging bootstrap), `swift/Sources/WendyUpdate/Output.swift` (JSON-lines progress + stdout/stderr split) |
| `cmd/wendyos-update/main.go`'s `install <url>` HTTP download path | `swift/Sources/WendyUpdate/Download.swift` (async-http-client streaming download) |
| `cmd/wendyos-update/pack.go` — `pack` verb (rootfs image → `.wendy`) | `swift/Sources/WendyUpdate/Pack.swift` |
| — (no Go equivalent; config resolution was inline in `main.go`) | `swift/Sources/WendyUpdate/Config.swift` |

### Artifact (`internal/artifact/`)

| Go | Swift |
|---|---|
| `internal/artifact/manifest.go` | `swift/Sources/Artifact/Manifest+Validate.swift`, `swift/Sources/Model/Model.swift` (manifest type itself lives in `Model`, shared with `Engine`) |
| `internal/artifact/reader.go` | `swift/Sources/Artifact/Reader.swift` |
| `internal/artifact/sparse.go` | `swift/Sources/Artifact/Sparse.swift` |
| `internal/artifact/writer.go` | `swift/Sources/Artifact/Writer.swift` |
| — | `swift/Sources/Artifact/ArtifactError.swift` (Go used bare `error`/`fmt.Errorf`; Swift gives artifact errors a typed, `ExitCoded` home) |

### BlockDev (`internal/blockdev/`)

| Go | Swift |
|---|---|
| `internal/blockdev/blockdev.go` — streams a payload onto a rootfs partition, gzip/zstd decompression, SHA-256 verify | `swift/Sources/BlockDev/BlockDev.swift` |

### Connector interface + registry (`internal/connector/`)

| Go | Swift |
|---|---|
| `internal/connector/connector.go` — `Connector` interface, `Slot` type | `swift/Sources/Connector/Connector.swift`, `swift/Sources/Connector/Slot.swift` |
| `internal/connector/registry.go` — auto-detect + explicit-override resolution | `swift/Sources/Connector/Registry.swift` |

### TegraUEFI connector (`internal/connector/tegrauefi/`)

| Go | Swift |
|---|---|
| `internal/connector/tegrauefi/tegrauefi.go` — controller, `CurrentSlot`/`ConfirmBoot`, boot-chain vs. rootfs-redundancy layer selection | `swift/Sources/TegraUEFI/TegraUEFI.swift` |
| `internal/connector/tegrauefi/efivar.go` | `swift/Sources/TegraUEFI/EfiVar.swift` |
| `internal/connector/tegrauefi/swap-slot.go` — `SwapSlot`, `nvbootctrlSlotArgs`, `bootChainSlotAB`, capsule staging | `swift/Sources/TegraUEFI/SwapSlot.swift` |
| `internal/connector/tegrauefi/diagnostics.go` | `swift/Sources/TegraUEFI/Diagnostics.swift` |
| `internal/connector/tegrauefi/verify.go` — ESRT verify cascade, abort, mark-good | `swift/Sources/TegraUEFI/Verify.swift` |
| — | `swift/Sources/TegraUEFI/Mount.swift` (mount helper factored out of the Go controller's inline mount calls), `swift/Sources/TegraUEFI/CommandRunner.swift` (thin `PlatformIO.CommandRunner` adapter), `swift/Sources/TegraUEFI/TegraUEFIError.swift` (typed, `ExitCoded` errors in place of Go's `fmt.Errorf` strings) |

### UBootEnv connector (`internal/connector/ubootenv/`)

| Go | Swift |
|---|---|
| `internal/connector/ubootenv/ubootenv.go` | `swift/Sources/UBootEnv/UBootEnv.swift` |
| `internal/connector/ubootenv/swap-slot.go` | `swift/Sources/UBootEnv/SwapSlot.swift` |
| `internal/connector/ubootenv/diagnostics.go` | `swift/Sources/UBootEnv/Diagnostics.swift` |
| `internal/connector/ubootenv/verify.go` | `swift/Sources/UBootEnv/Verify.swift` |
| — | `swift/Sources/UBootEnv/CommandRunner.swift` (`fw_setenv`/`fw_printenv` adapter over `PlatformIO.CommandRunner`), `swift/Sources/UBootEnv/UBootEnvError.swift` |

### Engine (`internal/engine/`)

| Go | Swift |
|---|---|
| `internal/engine/engine.go` — `Engine` struct/fields, `Install`, `Status`, `MarkGood`, state path helpers, `deviceType`, `versionAtLeast`/`parseVersion` | Split across `swift/Sources/Engine/Engine.swift` (struct + fields), `swift/Sources/Engine/Install.swift` (`Install`), `swift/Sources/Engine/Status.swift` (`Status`, `SlotState`/`StatusInfo`), `swift/Sources/Engine/State+Persistence.swift` (`MarkGood`, state path, load/save/clear), `swift/Sources/Engine/Policy.swift` (`versionAtLeast`/`parseVersion`), `swift/Sources/Engine/EngineError.swift` (`RejectError` and friends, typed/`ExitCoded`) |
| `internal/engine/commit.go` — `Commit`, `Rollback`, `Switch`, `VerifyBoot`, `confirmBoot`, `appendInstalled` | `swift/Sources/Engine/Commit.swift` |
| `internal/engine/hooks.go` — lifecycle hook phases, env vars, first-non-zero-exit semantics | `swift/Sources/Engine/Hooks.swift` |
| `internal/engine/slotinfo.go` — per-slot distro/kernel probing for `status --verbose` | `swift/Sources/Engine/VersionProbe.swift` (protocol + `RealVersionProbe`, mountable/testable in place of Go's free functions reading `/etc/os-release` directly) |
| `internal/engine/state.go` — `Phase`, `State`, `InstalledEntry`, `state.json` schema | `swift/Sources/Engine/Phase.swift`, `swift/Sources/Engine/State+Persistence.swift` (state types + persistence live together on the Swift side since both are small) |

### Logging (`internal/log/`)

| Go | Swift |
|---|---|
| `internal/log/log.go` — journal/tty/plain rendering, progress bar, stderr-only output | `swift/Packages/WendyLog/Sources/WendyLog/Handler.swift` (journal/tty/plain `LogHandler`), `swift/Packages/WendyLog/Sources/WendyLog/Mode.swift` (environment detection), `swift/Packages/WendyLog/Sources/WendyLog/Progress.swift` (progress-bar rendering) — a standalone local SwiftPM package rather than an `internal/`-style target, so it can be unit-tested and reused independently of `WendyUpdate` |

## New ecosystem packages (no Go equivalent)

Go got tar/zstd/structured-logging for free from the standard library and
`klauspost/compress`. Swift's ecosystem didn't have equivalents that fit
(static-musl-safe, no Foundation dependency for the hot paths), so this
rewrite built and vendored three local SwiftPM packages under
`swift/Packages/`:

- **`Tar`** (`swift/Packages/Tar/Sources/Tar/`: `TarEntry.swift`,
  `TarError.swift`, `TarHeader.swift`, `TarPath.swift`, `TarReader.swift`,
  `TarWriter.swift`) — ustar-format streaming reader/writer for `.wendy`
  archives, replacing Go's `archive/tar`.
- **`Zstd`** (`swift/Packages/Zstd/Sources/Zstd/`: `Backend.swift`,
  `CompressStream.swift`, `Compression.swift`, `DecompressStream.swift`,
  `GzipBackends.swift`, `ZstdBackends.swift`, plus the `CZstd` C shim
  target) — streaming zstd/gzip (de)compression over system `libzstd`/
  `zlib`, replacing `github.com/klauspost/compress/zstd` and
  `compress/gzip`.
- **`WendyLog`** (see above) — swift-log `LogHandler` + progress-bar
  package, replacing `internal/log`.

## Support layers with no direct Go equivalent

Go's standard library (`os`, `syscall`, `golang.org/x/sys/unix`) gave the
original implementation direct raw file/device/mount/ioctl access for free.
Swift has no single equivalent on musl, so the rewrite introduces explicit
seam layers:

- **`LinuxSys`** (`swift/Sources/LinuxSys/LinuxSys.swift`, backed by the
  `CLinuxSys` system-library target: `module.modulemap`, `shim.h`) — raw
  Linux syscalls/ioctls (mount, block-device size query, etc.) kept out of
  Foundation, which has gaps on musl.
- **`PlatformIO`** (`swift/Sources/PlatformIO/`: `BlockTarget.swift`,
  `Clock.swift`, `CommandRunner.swift`, `EnvReader.swift`,
  `FileStore.swift`, plus `Real/` implementations) — the fakeable seam for
  subprocess execution (via swift-subprocess), clock, environment, file
  I/O, and block-device writes that Go got away with calling directly
  (`exec.Command`, `os.*`, `time.Now()`) because Go tests mocked at a
  higher level or just didn't need to; the Swift port needed an explicit
  protocol boundary to keep `Engine`/connectors unit-testable without a
  real device. `PlatformIOTesting` (`FakeConnector.swift`, `Fakes.swift`)
  is the corresponding fake-implementation package, shared by `EngineTests`
  and `E2ETests`.
- **`CLIError`** (`swift/Sources/CLIError/ExitCoded.swift`) — a shared
  `ExitCoded` protocol so every layer's typed errors (Artifact, Engine,
  TegraUEFI, UBootEnv) carry their CLI exit code with them, rather than
  Go's pattern of sentinel error values (`RejectError`, `ErrNothingToCommit`,
  etc.) that `main.go` switched on by type/identity.
- **`Model`** (`swift/Sources/Model/Model.swift`, `Decode.swift`,
  `Encode.swift`) — the manifest/state JSON types plus explicit,
  order-preserving encode/decode over IkigaJSON's `JSONObject` (chosen over
  Foundation's `Codable`/`JSONDecoder`/`JSONEncoder` specifically so
  `status --json`'s key ordering is byte-reproducible — see the risk note
  in the design spec).

## Runtime / dependency notes

- **Toolchain**: Swift 6.3, strict concurrency (`swiftLanguageMode(.v6)`)
  on every target.
- **Deployment target**: fully static, musl-linked binary via the Static
  Linux SDK (`swift build --swift-sdk aarch64-swift-linux-musl -c release`,
  optionally pinned explicit with `WOS_STATIC_LINK=1`) — see
  `docs/swift-build.md` for the verified build/link commands. This
  replaces Go's default static-by-default cross-compiled binary.
- **JSON**: IkigaJSON (`swift-json` package) for order-preserving
  manifest/state encode+decode, not Foundation's `Codable`.
- **Crypto**: swift-crypto for the SHA-256 digests the Artifact
  reader/writer and BlockDev verify against (replacing Go's
  `crypto/sha256`).
- **HTTP**: async-http-client + swift-nio for `install <url>`'s streaming
  download (replacing Go's `net/http`); proven to link fully static against
  musl, so no `curl`-subprocess fallback was needed.
- **Subprocess execution**: swift-subprocess (+ swift-system's `FilePath`)
  for every `nvbootctrl`/`fw_setenv`/`fw_printenv`/mount shell-out
  (replacing Go's `os/exec`).
- **CLI**: swift-argument-parser for verb/flag dispatch (replacing Go's
  hand-rolled `os.Args[1]` switch in `main.go`).
- **Logging**: swift-log, with the `WendyLog` package supplying the
  journal/tty/plain `LogHandler` and progress-bar rendering (replacing
  `internal/log` built on `log/slog`).
- **Local packages**: `Tar` and `Zstd` (see above) are vendored as local
  SwiftPM packages under `swift/Packages/` rather than pulled from the
  registry, since no suitable musl-safe, Foundation-light equivalents
  existed upstream at rewrite time.

## Parity checklist

Copied from the design spec
(`docs/superpowers/specs/2026-07-05-wendyos-update-swift-rewrite-design.md`,
"Parity checklist" section) with an honest status per item. **"Ported +
tested" means: implemented in Swift and covered by `swift test` (host,
`aarch64-unknown-linux-gnu`, dynamic build) with fakes at the `PlatformIO`/
`Connector` seam — it does NOT mean validated against real hardware.**
Nothing in this port has been run against a real Jetson or Raspberry Pi.

- [x] **Verbs**: `install`, `commit`, `rollback`, `switch`,
      `status [--json] [--verbose]`, `mark-good`, `pack`, `verify-boot`,
      `version` — all implemented as swift-argument-parser subcommands in
      `WendyUpdate`, covered by `WendyUpdateTests`. Ported + tested on host.
- [x] **Exit codes 0/1/2/3/4 mapped identically** — `ExitCode.swift` +
      `CLIError.ExitCoded`, covered by `WendyUpdateTests/ExitCodeTests.swift`.
      Ported + tested on host.
- [x] **`status --json` object shape byte-compatible** (slots[]/system[]/
      pending/diagnostics; empty fields omitted; ordered system[]) — driven
      through IkigaJSON's order-preserving `JSONObject` specifically for
      this; covered by `EngineTests/StatusTests.swift` and
      `WendyUpdateTests/OutputTests.swift`. Ported + tested on host; **not**
      diffed byte-for-byte against a live Go binary's real device output.
- [x] **Progress JSON lines on stdout; suppressed on TTY** —
      `WendyUpdate/Output.swift`, covered by `WendyUpdateTests/OutputTests.swift`
      and `WendyLogTests`. Ported + tested on host.
- [x] **`state.json` phase ordering + atomic rename + `installed.json` cap
      10** — `Engine/Phase.swift` + `Engine/State+Persistence.swift`,
      covered by `EngineTests/StateTests.swift`. Ported + tested on host
      (real filesystem writes in a `TemporaryDirectory`, not a real `/data`
      partition).
- [x] **Hook phases + env vars + first-non-zero-exit semantics** —
      `Engine/Hooks.swift`, covered by `EngineTests/HooksTests.swift`.
      Ported + tested on host with fake hook scripts; not run against real
      systemd-managed hook directories.
- [x] **Connector boundary: no connector type leaks into `Engine`;
      auto-detect + explicit-override resolution and messages** —
      `Connector/Registry.swift`, covered by `ConnectorTests/RegistryTests.swift`
      and `EngineTests` (which only ever see `Connector`/`FakeConnector`).
      Ported + tested on host.
- [~] **Tegra**: `nvbootctrl` slot switch, efivar `RootfsStatusSlot*`
      reset, capsule/OsIndications staging, ESRT verify cascade, preflight
      refuse when A/B redundancy not armed, per-boot confirm — all
      implemented in `TegraUEFI/*.swift` and covered by
      `TegraUEFITests/*.swift` (`SwapSlotTests`, `EfiVarTests`,
      `DiagnosticsTests`, `VerifyTests`, `TegraUEFITests`). **Hardware-only-
      unverified**: every test fakes `nvbootctrl`/`efivarfs`/mount at the
      `PlatformIO.CommandRunner`/`FileStore` seam (recording fakes that
      assert the exact argv, not real command execution). None of this has
      run against a real Jetson's UEFI/efivars/ESRT/capsule firmware path.
- [~] **U-Boot**: `fw_setenv` trial-boot arming + fallback detection —
      implemented in `UBootEnv/*.swift`, covered by
      `UBootEnvTests/*.swift` (`FwEnvTests`, `SlotResolutionTests`,
      `SwapSlotTests`, `DiagnosticsTests`, `UBootEnvTests`).
      **Hardware-only-unverified**: `fw_setenv`/`fw_printenv` are faked at
      the `CommandRunner` seam; the real U-Boot environment shell-out has
      never run on a Raspberry Pi (or any real U-Boot board) in this repo.
- [x] **`.wendy` format**: tar (manifest-first), zstd/gzip/none, dual
      digests — `Artifact/*.swift` + the local `Tar`/`Zstd` packages,
      covered by `ArtifactTests/*.swift` (`ManifestValidateTests`,
      `ReaderTests`, `SparseTests`, `WriterTests`), `Tar`'s own
      `TarTests`, `Zstd`'s own `ZstdTests`, and end-to-end through
      `E2ETests/LifecycleTests.swift` (`ArtifactWriter.pack` → real
      `Engine.install`). Ported + tested on host. The real block-device
      write path in `BlockDev`/`PlatformIO.RealBlockTarget` is exercised
      by `PlatformIOTests/RealImplTests.swift` and `BlockDevTests` against
      real files/loop-like targets on the host filesystem, but never
      against a real rootfs partition on a booted device.

**Summary**: everything in the checklist is ported and covered by host
unit/E2E tests (339/339 green under `scripts/dsw test` as of the last
commit on this branch). The two items marked `[~]` (Tegra, U-Boot) are
implemented and unit-tested but are the hardware-facing halves of the tool
— their real command/efivar/mount effects have only been exercised through
recording/scripted fakes, never against physical Jetson or Raspberry Pi
hardware. Do not treat a green `swift test` run as hardware sign-off; see
`README.md`'s "Swift rewrite (in progress)" section.

## Notes / upstream deltas

Two findings worth a reviewer's attention and, in the second case, an
upstream Go-side fix:

1. **Orin boot-chain A/B merged in.** While this branch was in flight,
   `origin/main` landed a Go-side change (see `20ec14e`/`25df670`
   "tegrauefi: drive boot-chain A/B on Orin (no unarmable
   RootfsRedundancyLevel)") teaching the tegrauefi connector that on Orin
   (`tegra234`) the `RootfsRedundancyLevel` UEFI variable is unarmable from
   the OS, so `nvbootctrl -t rootfs` slot operations silently no-op there;
   Orin instead drives the coupled boot-chain layer directly (`nvbootctrl`
   without `-t rootfs`), while Thor (`tegra264`) and unknown SoCs keep the
   rootfs-redundancy path. This branch merged that change
   (`d9ed3a5` merge commit) and ported it in `f2640ad` ("feat(tegrauefi):
   Orin boot-chain A/B slot layer (sync with main)"), adding
   `socCompatibleContains`/`bootChainSlotAB`/`nvbootctrlSlotArgs` to
   `swift/Sources/TegraUEFI/SwapSlot.swift` and `TegraUEFI.swift`. The
   Swift port is current with `main` on this point.

2. **Upstream Go test `TestSwapSlotSwitchesSlotWhenCapsuleIneffective` is
   now stale.** In `internal/connector/tegrauefi/swap-slot_test.go`, this
   test builds a `tegra234` (Orin) fixture and asserts the recorded
   `nvbootctrl` call contains the literal string `-t rootfs
   set-active-boot-slot 1`. But per the `nvbootctrlSlotArgs` refactor
   above, `bootChainSlotAB()` is true for `tegra234`, so
   `nvbootctrlSlotArgs()` returns `[]` (no `-t rootfs`) on that exact
   fixture — the real call `Controller.SwapSlot` makes on today's `main` is
   `nvbootctrl set-active-boot-slot 1`, without `-t rootfs`. Confirmed by
   actually running it (`docker run ... golang:1.26-rc go test
   ./internal/connector/tegrauefi/... -run
   TestSwapSlotSwitchesSlotWhenCapsuleIneffective -v` on this branch): it
   **fails** —
   `swap-slot_test.go:112: expected nvbootctrl slot switch to B; calls
   were: set-active-boot-slot 1`. This is a real, currently-failing
   upstream test, not a hypothetical. The Swift port
   (`swift/Tests/TegraUEFITests/SwapSlotTests.swift`,
   `swapSlotSwitchesSlotWhenCapsuleIneffective`) matches the *actual*
   current Go **behavior** (asserts `set-active-boot-slot 1` without
   `-t rootfs` on the Orin fixture) rather than the stale Go **test**, and
   documents the discrepancy inline. This is worth an upstream fix to the
   Go test so it doesn't silently regress-test the wrong thing going
   forward.
