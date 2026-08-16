# wendyos-update Swift 6.3 Rewrite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reimplement `wendyos-update` in Swift 6.3 at full behavioral parity with the Go tool, as a testable draft PR that runs `swift test` green on a plain Linux host.

**Architecture:** Full Swift (not Embedded), statically linked with the Swift Static Linux SDK (Musl) into one self-contained aarch64 binary. Domain modules mirror Go's `internal/`; every side-effecting boundary (subprocess, filesystem, block device, clock, env) is a protocol faked in tests. Reusable pieces (`Tar`, `Zstd`, log handler) are local SwiftPM packages, extractable later.

**Tech Stack:** Swift 6.3 · swift-argument-parser · async-http-client · swift-crypto · orlandos-nl/swift-json (IkigaJSON) · wendylabsinc/swift-json-schema · swiftlang/swift-subprocess · swift-log · system libzstd/zlib.

## The Go source is the behavioral oracle

The Go tree stays in-repo throughout this PR. **Every task cites the exact Go file(s) it ports.** The Go code is the specification of behavior: when a task says "port `internal/engine/commit.go`", reproduce its control flow, log messages, and error text exactly unless the task notes a deliberate Swift idiom change. Do not re-derive behavior — read the cited Go and match it. Frozen contracts: `docs/cli-contract.md`, `docs/manifest-schema.md`, `docs/state-schema.md`, `docs/connector-architecture.md`.

## Global Constraints

- Swift tools/language version **6.0+**, language mode **6** (strict concurrency), toolchain **6.3**.
- Target triple for release: `aarch64-swift-linux-musl` via the Static Linux SDK; host testing builds native + `x86_64-swift-linux-musl`.
- **No contract changes.** Verbs, exit codes (0/1/2/3/4), `status --json` shape, JSON-lines progress, state-file ordering, and the connector boundary are frozen and reproduced exactly.
- **Do not delete or modify the Go tree** (`cmd/`, `internal/`, `go.mod`, `vendor/`). Swift is purely additive this PR.
- All Swift lives under `swift/` (SwiftPM root) with local packages under `swift/Packages/`.
- The existing `systemd/` units ship unchanged and must keep working (same verbs, same stderr/stdout behavior).
- State files and `status --json` must be **byte-reproducible**: JSON keys in a fixed order, 2-space indent for `state.json`/`installed.json`/`status --json` (matching Go `json.MarshalIndent`), compact single-line JSON for progress/`done`/`switch`/`rollback` events (matching Go `json.Marshal`). Golden-file tests enforce this.
- Every stderr line is tagged `wendyos-update: `. Journal mode is selected by `$JOURNAL_STREAM`; `WENDY_DEBUG=1` enables debug records; `NO_COLOR` disables color.
- Frequent commits: one per task minimum (each task ends with a commit step).

## File / target structure

```
swift/
  Package.swift                      # root package: executable + app-logic targets
  Packages/
    Tar/         (Package.swift, Sources/Tar, Tests/TarTests)
    Zstd/        (Package.swift, Sources/CZstd [system-lib], Sources/Zstd, Tests/ZstdTests)
    WendyLog/    (Package.swift, Sources/WendyLog, Tests/WendyLogTests)   # swift-log handler + progress
  Sources/
    LinuxSys/         # raw syscalls Foundation won't do (C shim + Swift wrapper)
    PlatformIO/       # FileStore / CommandRunner / BlockTarget / Clock / EnvReader protocols + real impls
    Model/            # schema-generated JSON models + IkigaJSON encode helpers
    Artifact/         # .wendy read/write/pack (manifest, reader, writer, sparse)
    BlockDev/         # payload -> device streaming + rolling sha256 + capacity
    Connector/        # Connector protocol, Slot, registry
    TegraUEFI/        # Jetson connector
    UBootEnv/         # U-Boot connector
    Engine/           # sequencing + state machine + hooks
    WendyUpdate/      # @main executable: argument-parser verbs, download, exit codes, pack
  Schemas/            # JSON Schema files consumed by the swift-json-schema plugin
  Tests/
    <TargetName>Tests/
  Fixtures/           # golden JSON, recorded command outputs, tiny test artifacts
docs/
  swift-build.md      # toolchain + static-musl + docker + Yocto notes
  go-to-swift-map.md  # file-by-file mapping (Go -> Swift target)
```

---

## Phase 0 — Scaffold, build, CI

### Task 0.1: SwiftPM root package skeleton + smoke test

**Files:**
- Create: `swift/Package.swift`
- Create: `swift/Sources/WendyUpdate/main.swift` (temporary stub)
- Create: `swift/Tests/WendyUpdateTests/SmokeTests.swift`
- Create: `swift/.gitignore` (`.build/`, `*.xcodeproj`)

**Interfaces:**
- Produces: a buildable `wendyos-update` executable product and a `swift test` target.

- [ ] **Step 1: Write the failing test**
```swift
import Testing
@testable import WendyUpdate

@Test func toolVersionIsSemver() {
    #expect(WendyUpdate.version == "0.1.0-dev")
}
```
- [ ] **Step 2: Run and confirm it fails** — `cd swift && swift test` → FAIL (no `WendyUpdate.version`).
- [ ] **Step 3: Minimal `Package.swift`** — `swift-tools-version:6.0`, platforms none (Linux), one executable target `WendyUpdate`, one test target `WendyUpdateTests` depending on it, and the `swift-testing` package is bundled with the toolchain (use `import Testing`). Add an `enum WendyUpdate { static let version = "0.1.0-dev" }` and a `@main`-less `main.swift` printing usage.
- [ ] **Step 4: Run** — `swift test` → PASS.
- [ ] **Step 5: Commit** — `git add swift && git commit -m "feat(swift): package skeleton + smoke test"`.

### Task 0.2: Static-musl build wiring + docker dev image + build docs

**Files:**
- Create: `swift/docker/Dockerfile` (Swift 6.3 toolchain image; installs Static Linux SDK)
- Create: `docs/swift-build.md`
- Modify: `swift/Package.swift` (add static-stdlib linker settings behind a trait/condition)

**Interfaces:**
- Produces: documented commands `swift build --swift-sdk aarch64-swift-linux-musl -c release` and `docker build/run` for host `swift test`.

- [ ] **Step 1:** Write `docs/swift-build.md`: prerequisites (`swiftly`/toolchain 6.3, `swift sdk install <static-linux-sdk-url>`), host test command, cross build command, and the note that tests are Linux-only (see `MEMORY.md`).
- [ ] **Step 2:** Add the docker image (base `swift:6.3` or the static SDK image) that runs `swift test`.
- [ ] **Step 3:** Verify host build+test in docker: `docker build -t wos-swift swift/docker && docker run --rm -v "$PWD/swift:/w" -w /w wos-swift swift test` → PASS.
- [ ] **Step 4 (best-effort, may defer to Phase 8 risk-check):** attempt `swift build --swift-sdk aarch64-swift-linux-musl` of the current skeleton; document the exact SDK identifier that works.
- [ ] **Step 5: Commit** — `git commit -m "build(swift): static-musl SDK wiring + docker dev image + build docs"`.

---

## Phase 1 — Ecosystem packages & platform seams

### Task 1.1: `Tar` package — streaming ustar reader

**Files:**
- Create: `swift/Packages/Tar/Package.swift`, `Sources/Tar/{TarReader,TarHeader,TarError}.swift`
- Create: `swift/Packages/Tar/Tests/TarTests/TarReaderTests.swift`

**Ports:** the read side of Go `archive/tar` as used by `internal/artifact/reader.go` (member name normalization `./x` == `x`, header size, sequential `next()`).

**Interfaces:**
- Produces:
```swift
public struct TarEntry: Sendable { public let name: String; public let size: Int64 }
public struct TarReader<Source: AsyncSequence> where Source.Element == ArrayView<UInt8> { ... }
// Simpler synchronous form used by the file/host path:
public final class TarReader {
    public init(_ read: @escaping (_ into: inout [UInt8], _ max: Int) throws -> Int)
    public func next() throws -> TarEntry?          // advances to next member header
    public func read(into buf: inout [UInt8]) throws -> Int  // reads current member body
}
public enum TarError: Error, Equatable { case truncated, badHeader, notTar }
```
- Consumes: nothing (leaf package).

- [ ] **Step 1: Failing test** — build a 512-byte ustar header for `manifest.json` size 5 + body `hello` + padding, feed bytes; expect `next()?.name == "manifest.json"`, `size == 5`, `read` yields `hello`, second `next()` returns `nil`. Include a `./manifest.json` normalization case.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement ustar parsing (name, prefix, octal size fields, checksum tolerant like Go, 512-byte block alignment). Name normalization mirrors `memberName` in `reader.go:110`.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5: Commit.**

### Task 1.2: `Tar` package — streaming writer

**Files:** Modify `Sources/Tar/TarWriter.swift`; add `Tests/TarTests/TarWriterTests.swift`.

**Ports:** the write side used by `internal/artifact/writer.go` (fixed member order, ustar headers).

**Interfaces:**
- Produces:
```swift
public final class TarWriter {
    public init(_ write: @escaping ([UInt8]) throws -> Void)
    public func writeHeader(name: String, size: Int64, mode: UInt32) throws
    public func write(_ bytes: ArraySlice<UInt8>) throws
    public func finish() throws                      // two zero blocks
}
```
- [ ] **Step 1: Failing round-trip test** — write `manifest.json`(body A) then `payload`(body B) with `TarWriter`, read back with `TarReader`, assert names/sizes/bodies and member order.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit.

### Task 1.3: `Zstd` package — libzstd/zlib decompress + compress

**Files:**
- Create: `swift/Packages/Zstd/Package.swift`
- Create: `Sources/CZstd/module.modulemap` + `shim.h` (links `libzstd`, `libz`)
- Create: `Sources/Zstd/{Decompressor,Compressor,Compression}.swift`
- Create: `Tests/ZstdTests/RoundTripTests.swift`

**Ports:** `internal/blockdev/blockdev.go` `Decompressor` (zstd/gzip/none) + the compress path used by `writer.go`.

**Interfaces:**
- Produces:
```swift
public enum Compression: String, Sendable { case zstd, gzip, none }
public struct DecompressStream {           // streaming pull
    public init(_ compression: Compression, source: @escaping (inout [UInt8], Int) throws -> Int)
    public func read(into: inout [UInt8]) throws -> Int   // 0 == EOF
}
public struct CompressStream {
    public init(_ compression: Compression, sink: @escaping (ArraySlice<UInt8>) throws -> Void)
    public func write(_ bytes: ArraySlice<UInt8>) throws
    public func finish() throws
}
public enum ZstdError: Error { case initFailed, corrupt(String), unsupported(String) }
```
- Consumes: system `libzstd`, `libz`.

- [ ] **Step 1: Failing test** — for each of `.zstd`, `.gzip`, `.none`: compress a 1 MiB pseudorandom (fixed-seed) buffer with `CompressStream`, decompress with `DecompressStream`, assert byte-identical. Add a corrupt-input test expecting `ZstdError.corrupt`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement over `ZSTD_*` streaming API and zlib `inflate`/`deflate` (gzip window bits). `.none` passes through. **Step 4:** PASS. **Step 5:** Commit.

### Task 1.4: `LinuxSys` — raw syscall shim

**Files:**
- Create: `swift/Sources/CLinuxSys/{module.modulemap,shim.h}`
- Create: `swift/Sources/LinuxSys/LinuxSys.swift`
- Create: `swift/Tests/LinuxSysTests/LinuxSysTests.swift`

**Ports:** the raw ops behind `blockdev.go` (`O_WRONLY` no-create open, `fsync`, `lseek(SEEK_END)`), `internal/log/log.go` `IsTTY` (`ioctl TCGETS`), and Tegra efivar immutable-flag toggling.

**Interfaces:**
- Produces:
```swift
public enum LinuxSys {
    public static func openWriteExisting(_ path: String) throws -> Int32   // O_WRONLY, no O_CREAT
    public static func openRead(_ path: String) throws -> Int32
    public static func write(_ fd: Int32, _ buf: UnsafeRawBufferPointer) throws -> Int
    public static func read(_ fd: Int32, _ buf: UnsafeMutableRawBufferPointer) throws -> Int
    public static func fsync(_ fd: Int32) throws
    public static func seekEnd(_ fd: Int32) throws -> Int64                 // capacity
    public static func close(_ fd: Int32)
    public static func isatty(_ fd: Int32) -> Bool
    public static func setImmutable(_ path: String, _ on: Bool) throws      // FS_IOC_GET/SETFLAGS
}
public struct SysError: Error, Equatable { public let errno: Int32; public let op: String }
```
- [ ] **Step 1: Failing test** — `openWriteExisting` on a nonexistent path throws `SysError`(ENOENT); create a temp file, write bytes, `fsync`, reopen read, `seekEnd` equals byte count; `isatty(fd)` for a pipe is false. (`setImmutable` needs privileges — test only that it throws cleanly as non-root, gated so CI passes.)
- [ ] **Step 2:** FAIL. **Step 3:** Implement via `Glibc`/`Musl` + the C shim for `FS_IOC_*`/`TCGETS`. **Step 4:** PASS. **Step 5:** Commit.

### Task 1.5: `PlatformIO` protocols + real implementations + fakes

**Files:**
- Create: `swift/Sources/PlatformIO/{FileStore,CommandRunner,BlockTarget,Clock,EnvReader}.swift`
- Create: `swift/Sources/PlatformIO/Real/*.swift` (real impls over Foundation + `LinuxSys` + swift-subprocess)
- Create: `swift/Sources/PlatformIOTesting/Fakes.swift` (a separate target so tests reuse fakes)
- Create: `swift/Tests/PlatformIOTests/RealImplTests.swift`

**Ports:** the file/exec/env operations scattered through `engine/*.go` (`os.ReadFile`, atomic write via tmp+rename+fsync in `SaveState`, `os.ReadDir`, `exec.Command` in `hooks.go`), and `os.Getenv` usage in `log.go`/`main.go`.

**Interfaces:**
- Produces:
```swift
public protocol FileStore: Sendable {
    func read(_ path: String) throws -> [UInt8]
    func exists(_ path: String) -> Bool
    func writeAtomic(_ path: String, _ bytes: [UInt8], mode: UInt32) throws  // tmp + fsync + rename
    func remove(_ path: String) throws                                       // no error if absent
    func mkdirp(_ path: String, mode: UInt32) throws
    func listDir(_ path: String) throws -> [DirEntry]                        // name, isDir, isExecutable
}
public struct DirEntry: Sendable { public let name: String; public let isDir, isExecutable: Bool }

public struct CommandResult: Sendable { public let exitCode: Int32; public let stdout: [UInt8]; public let stderr: [UInt8] }
public protocol CommandRunner: Sendable {
    func run(_ argv: [String], env: [String: String]?, stdin: [UInt8]?) async throws -> CommandResult
    // streaming variant for hooks whose output is line-logged live:
    func runStreaming(_ argv: [String], env: [String: String], onLine: @Sendable (String) -> Void) async throws -> Int32
}
public protocol BlockTarget: Sendable {
    func openForWrite(_ path: String) throws -> any WritableDevice
    func capacity(_ path: String) throws -> Int64
}
public protocol WritableDevice { func write(_ b: ArraySlice<UInt8>) throws; func sync() throws; func close() }
public protocol Clock: Sendable { func nowUTCISO8601() -> String }   // RFC3339 "2006-01-02T15:04:05Z"
public protocol EnvReader: Sendable { func get(_ key: String) -> String? }
```
- Consumes: `LinuxSys`, `swift-subprocess`, Foundation (`FileManager` for `listDir`).

- [ ] **Step 1: Failing tests** — `RealFileStore.writeAtomic` creates parent dirs, leaves no `.tmp`, content matches; `remove` of absent path is a no-op; `listDir` reports `isExecutable` from mode bits; `RealCommandRunner.run(["/bin/echo","hi"])` yields exit 0 and `stdout == "hi\n"`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement `Real*` and the in-memory `FakeFileStore`, `FakeCommandRunner` (records argv, returns scripted `CommandResult` by command match), `FixedClock`, `MapEnv` in `PlatformIOTesting`. **Step 4:** PASS. **Step 5:** Commit.

---

## Phase 2 — JSON models

### Task 2.1: JSON Schemas + swift-json-schema plugin wiring

**Files:**
- Create: `swift/Schemas/{manifest,state,installed,config}.schema.json`
- Create: `swift/Sources/Model/Model.swift` (re-exports generated types; hand-written where the plugin can't)
- Modify: `swift/Package.swift` (add `swift-json`, `swift-json-schema`; attach `JSONSchemaPlugin` to `Model`)
- Create: `swift/Tests/ModelTests/DecodeTests.swift`

**Ports:** the structs + JSON tags in `internal/artifact/manifest.go` (`Manifest`, `Payload`), `internal/engine/state.go` (`State`, `InstalledHistory`, `InstalledEntry`), `cmd/wendyos-update/main.go` (`Config`).

**Interfaces:**
- Produces (names/types fixed for all downstream tasks):
```swift
public struct Manifest: Sendable { public var formatVersion: Int; public var artifactName, artifactVersion: String
    public var compatibleDevices: [String]; public var payload: Payload; public var bootloaderUpdate: Bool; public var minToolVersion: String }
public struct Payload: Sendable { public var name: String; public var size: Int64; public var sha256, compressedSHA256, compression: String }
public struct State: Sendable { public var schema: Int; public var phase: String; public var targetSlot: Int
    public var artifactName, artifactVersion, payloadSHA256: String; public var bootloaderUpdate: Bool; public var created: String }
public struct InstalledEntry: Sendable { public var artifactName, artifactVersion, committed: String; public var slot: Int }
public struct InstalledHistory: Sendable { public var history: [InstalledEntry] }
public struct Config: Sendable { public var connector, deviceTypePath, stateDir, hooksDir, healthDir: String? }
```
- Produces JSON codec helpers (deterministic key order, matching Go tags exactly):
```swift
public enum JSONCodec {
    public static func decodeManifest(_ bytes: [UInt8]) throws -> Manifest
    public static func decodeState(_ bytes: [UInt8]) throws -> State
    public static func decodeInstalled(_ bytes: [UInt8]) throws -> InstalledHistory
    public static func decodeConfig(_ bytes: [UInt8]) throws -> Config
    public static func encodePretty(_ obj: JSONObject) -> [UInt8]   // 2-space indent + trailing \n
    public static func encodeCompact(_ obj: JSONObject) -> [UInt8]  // single line
}
public enum JSONError: Error { case malformed(String) }
```
- Consumes: IkigaJSON (`import IkigaJSON`), plugin-generated decoders.

- [ ] **Step 1: Failing test** — decode a sample `manifest.json` (copy the doc example into `Fixtures/`) → assert every field, including `compressed_sha256` mapping and `compression == "zstd"`. Decode a `state.json` sample → assert `phase == "swapped"`, `targetSlot == 1`, `created` round-trips the exact string.
- [ ] **Step 2:** FAIL. **Step 3:** Author schemas (snake_case JSON names, camelCase Swift via the plugin's name mapping), wire the plugin with the `SwiftJSON` trait, and implement `JSONCodec` encode via hand-built `JSONObject` to lock key order to the Go field order. **Step 4:** PASS. **Step 5:** Commit.

### Task 2.2: Encoder golden parity with Go

**Files:** Modify `Sources/Model/Model.swift`; add `Tests/ModelTests/GoldenEncodeTests.swift`; add goldens under `Fixtures/golden/`.

- [ ] **Step 1:** Generate goldens from Go: run the Go tool paths (or hand-copy known Go output) for a `State` and an `InstalledHistory` into `Fixtures/golden/state.json` / `installed.json` (2-space indent, trailing newline, key order: schema, phase, target_slot, artifact_name, artifact_version, payload_sha256, bootloader_update, created).
- [ ] **Step 2: Failing test** — `JSONCodec.encodePretty(state)` bytes `==` golden file bytes.
- [ ] **Step 3:** FAIL. **Step 4:** Adjust encoder key order/indent/newline until PASS. **Step 5:** Commit.

---

## Phase 3 — Artifact

### Task 3.1: Manifest validation

**Files:** Create `swift/Sources/Artifact/Manifest+Validate.swift`, `swift/Sources/Artifact/ArtifactError.swift`; test `Tests/ArtifactTests/ManifestValidateTests.swift`.

**Ports:** `internal/artifact/manifest.go` `Validate()` + `CompatibleWith()`.

**Interfaces:**
- Produces:
```swift
public enum ArtifactError: Error, Equatable, ExitCoded {   // ExitCoded from Engine task 5.1; forward-declare here as protocol in Artifact and conform
    case invalidManifest(String), notTar(String), payloadNotFound(String), payloadAlreadyTaken
    case sizeMismatch(got: Int64, want: Int64), sha256Mismatch(String)
    public var exitCode: Int32 { 3 }   // all artifact problems -> reject
}
public extension Manifest {
    func validate() throws                       // throws ArtifactError.invalidManifest
    func compatible(with deviceType: String) -> Bool
}
```
- [ ] **Step 1: Failing tests** — parity table from `Validate()`: `format_version != 1`, empty name/version, empty `compatible_devices`, empty `payload.name`, `sha256` wrong length, bad `compression` each throw with the matching message; a good manifest passes; `compatible(with:)` true/false.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit.

> Note on `ExitCoded`: define the protocol once (Task 5.1) and have `ArtifactError` conform. If Artifact is built before Engine, declare `public protocol ExitCoded: Error { var exitCode: Int32 { get } }` in a tiny `Sources/CLIError/` target that both depend on. Add that target in Task 3.1 Step 3.

### Task 3.2: Streaming Reader

**Files:** Create `Sources/Artifact/Reader.swift`; test `ReaderTests.swift`.

**Ports:** `internal/artifact/reader.go` exactly — manifest-first, `Payload()` once, tee compressed bytes through SHA-256, skip `manifest.sig`, `VerifyPayloadDigests`.

**Interfaces:**
- Produces:
```swift
public final class ArtifactReader {
    public let manifest: Manifest
    public static func open(_ tar: TarReader) throws -> ArtifactReader   // reads+validates manifest.json (first member)
    public func payload() throws -> PayloadStream                        // once; tees compressed bytes -> SHA256
    public func verifyPayloadDigests(uncompressedSHA256: String) throws  // compares both digests
}
public struct PayloadStream { public func read(into: inout [UInt8]) throws -> Int }
```
- Consumes: `Tar` (Task 1.1), `Crypto.SHA256`, `Model` digests. `maxManifestSize = 4 << 20`.

- [ ] **Step 1: Failing tests** — build an in-memory `.wendy` (Tar: manifest.json first, then `payload`), open, assert manifest parsed; reading payload then `verifyPayloadDigests` with the correct uncompressed hash passes; a wrong hash throws `.sha256Mismatch`; first member not `manifest.json` throws `.invalidManifest`/`.notTar`; second `payload()` call throws `.payloadAlreadyTaken`; a `manifest.sig` member before payload is skipped.
- [ ] **Step 2:** FAIL. **Step 3:** Implement, mirroring `reader.go` control flow and using `Crypto.SHA256` incrementally for the compressed-bytes tee. **Step 4:** PASS. **Step 5:** Commit.

### Task 3.3: Sparse-file expansion

**Files:** Create `Sources/Artifact/Sparse.swift`; test `SparseTests.swift`.

**Ports:** `internal/artifact/sparse.go` (whatever sparse/hole handling it does — read it and match, including any Android sparse or ext4 hole logic).

- [ ] **Step 1: Failing test** — replicate the Go `sparse_test.go` cases (copy inputs/expected). **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit.

### Task 3.4: Writer / Pack

**Files:** Create `Sources/Artifact/Writer.swift`; test `WriterTests.swift`.

**Ports:** `internal/artifact/writer.go` + `cmd/wendyos-update/pack.go` `PackOptions`/`Pack` (compute uncompressed sha256 + size, compress into the tar payload member, compute compressed sha256, emit manifest.json first).

**Interfaces:**
- Produces:
```swift
public struct PackOptions: Sendable {
    public var imagePath, artifactName, artifactVersion: String
    public var compatibleDevices: [String]; public var compression: Compression
    public var bootloaderUpdate: Bool; public var minToolVersion: String
}
public enum ArtifactWriter {
    public static func pack(to sink: @escaping ([UInt8]) throws -> Void, _ opts: PackOptions, fs: any FileStore) throws -> Manifest
}
```
- [ ] **Step 1: Failing test** — pack a small temp image → open the result with `ArtifactReader` → payload digests verify and size matches (the Go `pack` self-verify path, `verifyPacked`). Cover zstd + none.
- [ ] **Step 2:** FAIL. **Step 3:** Implement via `TarWriter` + `CompressStream` + `Crypto.SHA256`. **Step 4:** PASS. **Step 5:** Commit.

---

## Phase 4 — BlockDev

### Task 4.1: WriteImage + DeviceCapacity + Decompressor

**Files:** Create `Sources/BlockDev/BlockDev.swift`; test `BlockDevTests.swift`.

**Ports:** `internal/blockdev/blockdev.go` (`WriteImage`, `DeviceCapacity`, `Decompressor`) and its 1 MiB buffer, rolling sha256, fsync-before-return, `O_WRONLY`-no-create semantics.

**Interfaces:**
- Produces:
```swift
public enum BlockDev {
    // writes decompressed bytes of `payload` to `devicePath`, returns (bytesWritten, uncompressedSHA256Hex)
    public static func writeImage(to devicePath: String, from payload: PayloadStream, compression: Compression,
                                  target: any BlockTarget, progress: (Int64) -> Void) throws -> (Int64, String)
    public static func deviceCapacity(_ path: String, target: any BlockTarget) throws -> Int64
}
public enum BlockDevError: Error { case openTarget(String), write(String), readPayload(String), unsupportedCompression(String) }
```
- Consumes: `Zstd`, `Crypto.SHA256`, `PlatformIO.BlockTarget`, `LinuxSys`.

- [ ] **Step 1: Failing test** — with a `FakeBlockTarget` writing to a temp regular file: feed a zstd `PayloadStream` of known bytes; assert returned digest == sha256 of the decompressed bytes, byte count correct, file content matches, progress called with increasing values, `sync()` invoked. Add: opening a nonexistent device path throws `.openTarget` (via `LinuxSys.openWriteExisting`).
- [ ] **Step 2:** FAIL. **Step 3:** Implement (1 MiB buffer, `MultiWriter` equivalent = write to device + update hash). **Step 4:** PASS. **Step 5:** Commit.

---

## Phase 5 — Connector abstraction

### Task 5.1: Connector protocol, Slot, errors, registry

**Files:** Create `Sources/Connector/{Connector,Slot,Registry}.swift`, `Sources/CLIError/ExitCoded.swift`; test `Tests/ConnectorTests/RegistryTests.swift`.

**Ports:** `internal/connector/connector.go` (interface + `Slot` + optional protocols + `SlotStatus`/`KV`) and `internal/connector/registry.go` (`Register`/`Select`, resolution order + exact error text). Registration is **explicit** (no Go-style `init()`): the executable passes a connector list into `select`.

**Interfaces:**
- Produces:
```swift
public enum Slot: Int, Sendable, CustomStringConvertible { case a = 0, b = 1
    public var other: Slot { self == .a ? .b : .a }
    public var description: String { self == .a ? "A" : "B" } }
public struct SlotStatus: Sendable { public var rootfsHealth = "", retries = "", note = ""; public init() {} }
public struct KV: Sendable { public let key, value: String; public init(_ k: String, _ v: String) }

public protocol Connector: AnyObject, Sendable {
    var name: String { get }
    func currentSlot() throws -> Slot
    func partition(for s: Slot) throws -> String
    func prepareTarget(_ s: Slot) throws
    func swapSlot(_ s: Slot, stagePlatformUpdate: Bool) throws
    func bootIsCompromised() throws -> Bool
    func verifyPlatformUpdate(bootloaderUpdate: Bool) throws
    func abortPlatformUpdate() throws
    func markGood() throws
    func diagnostics(verbose: Bool) -> [String: String]
    func slotStatus(_ s: Slot) -> SlotStatus
    func systemStatus() -> [KV]
}
public protocol BootConfirmer: AnyObject { func confirmBoot() throws }
public protocol InstallPreflighter: AnyObject { func preflightInstall() throws }

public struct ConnectorFactory: Sendable { public let name: String; public let make: @Sendable () -> any Connector; public let detect: @Sendable () -> Bool }
public enum ConnectorError: Error, Equatable, ExitCoded {
    case notBuiltIn(name: String, have: [String]), noneDetected(have: [String]), ambiguous([String])
    public var exitCode: Int32 { 1 }
}
public enum ConnectorRegistry {
    public static func select(explicit: String?, from factories: [ConnectorFactory]) throws -> any Connector
}
```
- Produces (`CLIError` target): `public protocol ExitCoded: Error { var exitCode: Int32 { get } }`.

- [ ] **Step 1: Failing tests** — with two fake factories (`detect` true/false): explicit name selects it; unknown explicit throws `.notBuiltIn` with sorted `have`; exactly-one-detect selects; zero-detect throws `.noneDetected`; two-detect throws `.ambiguous(sorted)`. `Slot.a.other == .b`, `.description == "A"`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement (match `registry.go` messages). **Step 4:** PASS. **Step 5:** Commit.

---

## Phase 6 — Engine

Engine is one target; split into tasks by lifecycle. All engine types take injected `Connector`, `FileStore`, `CommandRunner`, `Clock`, `EnvReader` so tests fake the platform (mirrors Go `Engine` struct fields).

### Task 6.1: Engine core + state persistence

**Files:** Create `Sources/Engine/{Engine,State,StateStore}.swift`, `Sources/Engine/EngineError.swift`; test `Tests/EngineTests/StateTests.swift`.

**Ports:** `engine/state.go`, `engine/engine.go` state helpers (`LoadState`/`SaveState`/`ClearState` atomic tmp+fsync+rename), `deviceType()`, `versionAtLeast`/`parseVersion`, `StateDir`/`DefaultDeviceTypePath` consts, `RejectError`.

**Interfaces:**
- Produces:
```swift
public struct Engine: Sendable {
    public var conn: any Connector
    public var stateDir: String            // default StateDir "/data/wendyos-update"
    public var deviceTypePath: String      // "" -> "/etc/wendyos/device-type"
    public var hooksDir: String            // "" -> "/etc/wendyos-update"
    public var healthDir: String           // legacy health override
    public var toolVersion: String
    public var fs: any FileStore
    public var runner: any CommandRunner
    public var clock: any Clock
    public var env: any EnvReader
    public var progress: (@Sendable (_ phase: String, _ percent: Int) -> Void)?
    public func loadState() throws -> State?          // nil == none in flight
    public func saveState(_ s: State) throws
    public func clearState() throws
}
public enum EngineError: Error, Equatable, ExitCoded {
    case rejected(String)                 // exit 3
    case updateInFlight(phase: String, artifact: String)   // exit 1
    case deviceType(String)               // exit 1
    public var exitCode: Int32 { if case .rejected = self { return 3 }; return 1 }
}
public let StateDir = "/data/wendyos-update"
```
- [ ] **Step 1: Failing tests** — `saveState` then `loadState` round-trips (via `FakeFileStore`); `loadState` with no file returns `nil`; `clearState` on absent is fine; `deviceType()` parses `BOARD=` from a fixture and errors on a missing line; `versionAtLeast("0.2.0","0.1.0")==true`, `("0.1.0","0.2.0")==false`, malformed min gates nothing (true).
- [ ] **Step 2:** FAIL. **Step 3:** Implement; `saveState` writes via `fs.writeAtomic` (which does tmp+fsync+rename) with 2-space JSON + trailing newline. **Step 4:** PASS. **Step 5:** Commit.

### Task 6.2: Hooks runner

**Files:** Create `Sources/Engine/Hooks.swift`; test `HooksTests.swift`.

**Ports:** `engine/hooks.go` fully — phase dirs, lexical order, executable-only filter, `WENDY_*` env, first-non-zero → `HookError`, advisory phases log-only, live line logging (`hook[<name>] ...`), `HealthDir` legacy override.

**Interfaces:**
- Produces:
```swift
public struct HookError: Error, Equatable, ExitCoded {
    public let phase, hook: String; public let underlying: String
    public var exitCode: Int32 { phase == HookHealth ? 4 : 1 }
}
public let HookPreInstall = "pre-install", HookPostInstall = "post-install",
           HookHealth = "health", HookPostCommit = "post-commit", HookOnFailure = "on-failure"
extension Engine {
    func runHooks(_ phase: String, _ env: [String: String]) async throws
    func runAdvisoryHooks(_ phase: String, _ env: [String: String]) async
    func hookEnv(name: String, version: String, target: Slot, cur: Slot, blUpdate: Bool) -> [String: String]
}
```
- [ ] **Step 1: Failing tests** — `FakeFileStore` with a `pre-install.d/` holding two executable scripts `10-a`,`20-b` and one non-exec `readme`: `FakeCommandRunner` records run order `[10-a, 20-b]`; a scripted non-zero exit on `20-b` throws `HookError(phase:"pre-install")` with `exitCode==1`; a `health` failure yields `exitCode==4`; missing dir passes; `hookEnv` contains all six `WENDY_*` keys; `HealthDir` override is honored for `health` only.
- [ ] **Step 2:** FAIL. **Step 3:** Implement (`runner.runStreaming` for live `hook[..]` lines). **Step 4:** PASS. **Step 5:** Commit.

### Task 6.3: Install

**Files:** Create `Sources/Engine/Install.swift`; test `InstallTests.swift`.

**Ports:** `engine/engine.go` `Install(...)` end to end: one-in-flight guard, open+validate artifact, device/version gates, resolve target slot + partition, `InstallPreflighter` probe, capacity preflight, `pre-install` hooks, stream write via `BlockDev`, verify size+digests **before** persisting state, `saveState(written)`, `prepareTarget`, `swapSlot(target, stage:true)`, `saveState(swapped)`, `post-install` hooks with unwind on failure.

**Interfaces:**
- Produces:
```swift
public struct InstallResult: Sendable { public let artifactName, artifactVersion: String; public let targetSlot: Slot; public let bootloaderUpdate: Bool }
extension Engine {
    public func install(_ reader: ArtifactReader, blockTarget: any BlockTarget) async throws -> InstallResult
}
```
- [ ] **Step 1: Failing tests** (with a `FakeConnector` recording calls, `FakeBlockTarget`, in-memory `.wendy`):
  - happy path: state transitions written→swapped, `prepareTarget` then `swapSlot(.b, stage:true)` called in order, result fields correct;
  - already-in-flight state throws `.updateInFlight`;
  - device mismatch throws `.rejected` (exit 3) with nothing written;
  - `payload.size > capacity` throws `.rejected` before any write;
  - `PreflightInstall` error throws `.rejected`;
  - `pre-install` hook failure aborts with nothing written;
  - digest mismatch throws `.rejected` and no state saved;
  - `post-install` hook failure triggers unwind (`abortPlatformUpdate`, `swapSlot(cur,false)`, `clearState`) and rethrows.
- [ ] **Step 2:** FAIL. **Step 3:** Implement mirroring `engine.go` ordering precisely (state-schema ordering is safety-critical). **Step 4:** PASS. **Step 5:** Commit.

### Task 6.4: Commit + Rollback + Switch + VerifyBoot

**Files:** Create `Sources/Engine/Commit.swift`; test `CommitTests.swift`, `RollbackTests.swift`, `SwitchTests.swift`, `VerifyBootTests.swift`.

**Ports:** `engine/commit.go` fully — `Commit()`, `Rollback()`, `Switch()`, `VerifyBoot()`, `confirmBoot()`, `appendInstalled()` (cap 10), `ErrNothingToCommit`, `PlatformVerifyError`.

**Interfaces:**
- Produces:
```swift
public struct RollbackResult: Sendable { public let originSlot: Slot; public let rebootRequired: Bool }
public struct CommitError: Error, Equatable, ExitCoded {   // wraps the phase-specific failures
    public enum Kind: Equatable { case nothingToCommit, phaseFailed(String), platformVerify(String) }
    public let kind: Kind
    public var exitCode: Int32 { switch kind { case .nothingToCommit: return 2; case .platformVerify: return 4; case .phaseFailed: return 1 } }
}
extension Engine {
    public func commit() async throws
    public func rollback() throws -> RollbackResult
    public func `switch`(to target: Slot) throws
    public func verifyBoot() throws
}
```
- [ ] **Step 1: Failing tests** (FakeConnector):
  - **commit:** no state → `CommitError(.nothingToCommit)` (exit 2); phase `written`/`failed` → error; phase `swapped` but `currentSlot != target` → state marked `failed`, `on-failure` hooks run, `CommitError(.platformVerify)` (exit 4); `VerifyPlatformUpdate` error → same; `health` hook failure → state failed + exit 4; happy path → `MarkGood`, state cleared, `installed.json` appended (cap enforced at 10), `post-commit` advisory run.
  - **rollback:** no state → error; pre-reboot (cur==origin) calls `abortPlatformUpdate` then `swapSlot(origin,false)`, `rebootRequired==false`; post-reboot (cur==target) skips abort, `rebootRequired==true`.
  - **switch:** pending state → refuse; target==cur → refuse; else `prepareTarget`+`swapSlot(target,false)`.
  - **verifyBoot:** no state → `confirmBoot` only; `swapped`+compromised → mark failed, do **not** confirm; `swapped`+fallback (cur!=target) → mark failed but **do** confirm; healthy → confirm, no failure. Use a `FakeConnector` conforming to `BootConfirmer`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement, matching `commit.go` log lines and ordering. **Step 4:** PASS. **Step 5:** Commit.

### Task 6.5: Status + slot info

**Files:** Create `Sources/Engine/Status.swift`, `Sources/Engine/SlotInfo.swift`; test `StatusTests.swift`.

**Ports:** `engine.go` `Status()` + `engine/slotinfo.go` (`currentDistro`, `currentKernel`, `slotVersions` via best-effort read-only mount — behind `CommandRunner`/`FileStore` seams so tests fake them).

**Interfaces:**
- Produces:
```swift
public struct SlotState: Sendable { public var slot: String; public var booted: Bool
    public var partition, distro, kernel, rootfsHealth, retries, note: String }
public struct StatusInfo: Sendable {
    public var connector, currentSlot: String
    public var slots: [SlotState]; public var system: [KV]; public var pending: State?; public var diagnostics: [String: String]
}
extension Engine { public func status(verbose: Bool) throws -> StatusInfo }
```
- [ ] **Step 1: Failing tests** — with a FakeConnector returning partitions/health/system KVs and a pending state: assert `StatusInfo` fields; `slots[booted]` matches `currentSlot`; distro/kernel for booted slot come from the (faked) live source and for the inactive slot from the (faked) mount reader; empty fields present as "".
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit.

---

## Phase 7 — Logging & progress

### Task 7.1: `WendyLog` package — swift-log handler + progress reporter

**Files:** Create `swift/Packages/WendyLog/Package.swift`, `Sources/WendyLog/{Handler,Mode,Progress}.swift`; test `Tests/WendyLogTests/*`.

**Ports:** `internal/log/log.go` fully — `Mode` (plain/tty/journal), `Detect` ($JOURNAL_STREAM → journal, isatty → tty, else plain), sd-daemon `<3|4|6|7>` prefixes, `wendyos-update: ` tag, color (respect `NO_COLOR`), plain RFC3339 timestamps, `WENDY_DEBUG` gate, and the carriage-return progress bar (TTY only; no-op elsewhere) including the `%3d%%` + block/▁ bar and the `\r...\033[K` clearing so a log line never leaves a half-bar.

**Interfaces:**
- Produces:
```swift
public enum LogMode: Sendable { case plain, tty, journal }
public enum WendyLog {
    public static func detect(_ isTTY: Bool, env: any EnvReader) -> LogMode
    public static func handler(_ mode: LogMode, out: @escaping (String) -> Void, env: any EnvReader) -> any LogHandler  // swift-log
}
public final class ProgressReporter: Sendable {   // serializes with the handler over the same sink
    public init(mode: LogMode, out: @escaping (String) -> Void)
    public func update(phase: String, percent: Int)   // percent < 0 == indeterminate; TTY only draws
}
```
- Consumes: `swift-log`, `PlatformIO.EnvReader`.

- [ ] **Step 1: Failing tests** — `detect`: with `JOURNAL_STREAM` set → `.journal`; isTTY true, no journal → `.tty`; else `.plain`. Journal handler renders an error record as `<3>wendyos-update: msg`; plain renders `<rfc3339> ERROR wendyos-update: msg`; `NO_COLOR` disables ANSI on tty; debug record suppressed unless `WENDY_DEBUG`. `ProgressReporter.update` in `.plain`/`.journal` emits nothing; in `.tty` emits a `\r`-prefixed bar and a trailing `\n` at 100%.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit.

---

## Phase 8 — TegraUEFI connector

> Read the whole `internal/connector/tegrauefi/` package first. This is the hardware-validated core; reproduce its command strings and efivar byte handling exactly. All platform access goes through `CommandRunner` (nvbootctrl, lsblk, mount) and `FileStore`/`LinuxSys` (efivars read/write with the 4-byte attribute prefix and immutable-flag toggling).

### Task 8.1: efivar read/write primitive

**Files:** Create `Sources/TegraUEFI/EfiVar.swift`; test `EfiVarTests.swift`.

**Ports:** `tegrauefi/efivar.go` — path under `/sys/firmware/efi/efivars`, the 4-byte little-endian attributes prefix on read/write, `chattr -i` (immutable) removal before write and restore after (via `LinuxSys.setImmutable`), GUID handling.

**Interfaces:**
- Produces:
```swift
struct EfiVar { let name: String; let guid: String }   // internal to TegraUEFI
extension EfiVar {
    func read(_ fs: any FileStore) throws -> [UInt8]     // strips the 4-byte attr prefix
    func write(_ data: [UInt8], attrs: UInt32, fs: any FileStore) throws  // toggles immutable, writes prefix+data
}
```
- [ ] **Step 1: Failing tests** — a `FakeFileStore` seeded with `<attrs:4><payload>` bytes at the efivar path → `read` returns just `payload`; `write` produces `<attrs><payload>` and calls `setImmutable(false)` before and `setImmutable(true)` after (record via a fake). Match `efivar.go` byte layout.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit.

### Task 8.2: swap-slot, prepare, current-slot, partition resolution

**Files:** Create `Sources/TegraUEFI/{TegraUEFI,SwapSlot}.swift`; test `SwapSlotTests.swift`, `TegraUEFITests.swift`.

**Ports:** `tegrauefi/tegrauefi.go` + `tegrauefi/swap-slot.go` — `nvbootctrl -t rootfs get-current-slot`; `PartitionFor` (partlabel APP/APP_b → lsblk → nv_boot_control.conf → number toggle); `PrepareTarget` (reset `RootfsStatusSlot*` + reseed retry budget); `SwapSlot` install path (capsule staging + OsIndications, no nvbootctrl) vs `set-active-boot-slot`; rollback path (pure `set-active-boot-slot`, no mount); `InstallPreflighter` (refuse when rootfs A/B redundancy not armed — see commit `33da342`); `BootConfirmer.confirmBoot`.

**Interfaces:**
- Produces: `final class TegraUEFI: Connector, BootConfirmer, InstallPreflighter` + `static let factory: ConnectorFactory` (name `"tegrauefi"`, `detect` = nvbootctrl present + NVIDIA efivar GUID visible).

- [ ] **Step 1: Failing tests** — port `swap-slot_test.go` and `tegrauefi_test.go` cases using `FakeCommandRunner` (scripted `nvbootctrl`/`lsblk` outputs) + `FakeFileStore` (efivars, nv_boot_control.conf): current-slot parse; partition resolution each fallback tier; install swap stages capsule + sets OsIndications and does **not** call `set-active-boot-slot` when the rootfs marker is present, else calls it; rollback swap only calls `set-active-boot-slot` and never mounts; preflight refuses when redundancy not armed; `confirmBoot` writes the expected efivar.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit.

### Task 8.3: verify (ESRT cascade), abort, mark-good

**Files:** Create `Sources/TegraUEFI/Verify.swift`; test `VerifyTests.swift`.

**Ports:** `tegrauefi/verify.go` — `VerifyPlatformUpdate` (BL version + ESRT cascade), `AbortPlatformUpdate` (remove staged capsule + disarm OsIndications), `MarkGood` (clear bookkeeping + reset inactive slot status var).

- [ ] **Step 1: Failing tests** — port `verify_test.go`: BL-version match/mismatch, ESRT last-attempt-status success/failure, abort removes the capsule file + clears OsIndications, mark-good resets the inactive `RootfsStatusSlot*`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit.

### Task 8.4: diagnostics + slot/system status

**Files:** Create `Sources/TegraUEFI/Diagnostics.swift`; test `DiagnosticsTests.swift`.

**Ports:** `tegrauefi/diagnostics.go` — `Diagnostics(verbose)`, `SlotStatus`, `SystemStatus` (raw status bytes, per-slot bootloader state, `BootChainFw*`, `OsIndications`, BL version, last capsule status).

- [ ] **Step 1: Failing tests** — seeded efivars/command outputs → assert the exact diagnostic keys/values and that verbose adds the raw snapshot; unreadable items omitted. **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit.

---

## Phase 9 — UBootEnv connector

### Task 9.1: fw_printenv/fw_setenv core + swap + detect

**Files:** Create `Sources/UBootEnv/{UBootEnv,SwapSlot}.swift`; test `UBootEnvTests.swift`, `SwapSlotTests.swift`.

**Ports:** `internal/connector/ubootenv/ubootenv.go` + `swap-slot.go` — current slot from `/proc/cmdline` or `fw_printenv` slot var; fixed p2/p3 or PARTUUID partition map; `PrepareTarget` clears stale trial state; `SwapSlot` install arms trial boot (`bootcount=0`, `upgrade_available=1`) via `fw_setenv`, rollback re-points only; `BootIsCompromised` (`upgrade_available=1` but running old slot); `Detect` (`fw_printenv` present + our env layout). No `BootConfirmer` (bootcount stays armed until commit).

- [ ] **Step 1: Failing tests** — port `ubootenv_test.go` with `FakeCommandRunner` scripting `fw_printenv`/`fw_setenv` and a fake `/proc/cmdline`: current slot both ways; partition map; install swap sets the trial vars; rollback re-points only; compromised detection; detect true/false.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit.

### Task 9.2: verify + diagnostics (v1 no-ops + status)

**Files:** Create `Sources/UBootEnv/{Verify,Diagnostics}.swift`; test as needed.

**Ports:** `ubootenv/verify.go` (v1 no-op `VerifyPlatformUpdate`/`AbortPlatformUpdate`) + `ubootenv/diagnostics.go` (slot vars, `upgrade_available`, `bootcount`).

- [ ] **Step 1: Failing tests** — verify is a clean no-op; diagnostics/slot/system status render the U-Boot vars. **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit.

---

## Phase 10 — CLI executable

### Task 10.1: argument-parser verbs + config + exit-code mapping

**Files:** Replace `Sources/WendyUpdate/main.swift` with `Sources/WendyUpdate/{Command,Config,ExitCode,Output}.swift`; test `Tests/WendyUpdateTests/{ExitCodeTests,ConfigTests,OutputTests}.swift`.

**Ports:** `cmd/wendyos-update/main.go` — verb dispatch (`install/commit/rollback/status/switch/mark-good/pack/verify-boot/version`), `Config` load from `/etc/wendyos-update/config.json` (absent = defaults, malformed = warn+defaults), `newEngine()` assembly (connector `select` with the built-in factory list `[TegraUEFI.factory, UBootEnv.factory]`), `exitCode(err)` mapping via `ExitCoded`, stdout JSON events (compact) vs stderr logs, TTY-suppression of progress JSON, usage text.

**Interfaces:**
- Produces: an `AsyncParsableCommand` root `WendyUpdate` with subcommands; `func mapExit(_ error: any Error) -> Int32` (uses `ExitCoded`, default 1); output helpers `emitProgressJSON`, `emitEvent`.

- [ ] **Step 1: Failing tests** — `mapExit`: `CommitError(.nothingToCommit)`→2, `ArtifactError`→3, `EngineError.rejected`→3, `CommitError(.platformVerify)`→4, `HookError(health)`→4, `HookError(pre-install)`→1, unknown→1. `Config` decode of absent → defaults; malformed → defaults (no throw). Progress JSON suppressed when stdout non-TTY flag is false.
- [ ] **Step 2:** FAIL. **Step 3:** Implement subcommands (each builds the engine and calls the matching method; format stdout events to match `main.go` `json.Marshal` maps: `install`→`done`/reboot_required, `switch`, `rollback`, `status --json`). **Step 4:** PASS. **Step 5:** Commit.

### Task 10.2: install download (async-http-client) + local/stdin source

**Files:** Create `Sources/WendyUpdate/Download.swift`; test `DownloadTests.swift`.

**Ports:** `main.go` `cmdInstall` — http(s) via async-http-client streaming (per-stage timeouts: dial/TLS/response-header bounded, no overall body timeout), non-200 → error; else open local file; feed bytes into `ArtifactReader`(over a `TarReader` fed by the stream); SIGINT/SIGTERM cancels and aborts partial write.

**Interfaces:**
- Produces:
```swift
enum Source { case url(String), file(String) }
func openArtifactSource(_ src: String, httpClient: HTTPClient) async throws -> TarReader  // streams bytes
```
- [ ] **Step 1: Failing tests** — a local temp `.wendy` opens and installs (integration with FakeConnector/FakeBlockTarget end-to-end, exit 0, correct stdout `done` JSON). URL path: spin a local HTTP server serving a temp `.wendy` (async-http-client against `127.0.0.1`), assert install succeeds; a 404 yields exit 1 with a download error. (No TLS needed in test; plain HTTP to localhost.)
- [ ] **Step 2:** FAIL. **Step 3:** Implement; wire cancellation via a `Task` + signal handler. If BoringSSL-on-musl proves unavailable at Task 0.2, gate TLS behind the documented `curl` `CommandRunner` fallback and note it. **Step 4:** PASS. **Step 5:** Commit.

### Task 10.3: pack verb

**Files:** Create `Sources/WendyUpdate/Pack.swift`; test `PackCLITests.swift`.

**Ports:** `cmd/wendyos-update/pack.go` — flags (`--image --name --version --compression --bootloader-update --min-tool-version -o --no-verify --device` repeatable), required-flag checks, `ArtifactWriter.pack`, self-verify read-back, stderr summary line, cleanup on failure.

- [ ] **Step 1: Failing test** — `pack --image tmp.img --name n --version 0.1.0 --device d -o out.wendy` produces a file that re-opens and verifies; missing required flags error; `--no-verify` skips the read-back. **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit.

---

## Phase 11 — Integration, parity, PR

### Task 11.1: End-to-end lifecycle test (fake platform)

**Files:** Create `swift/Tests/E2ETests/LifecycleTests.swift`.

- [ ] **Step 1:** With FakeConnector + FakeBlockTarget + FakeFileStore, drive the full sequence: `pack` → `install` (state=swapped) → simulate reboot onto target → `commit` (state cleared, installed.json appended) and, separately, the failure branch: `install` → simulate fallback → `verifyBoot` marks failed → `rollback`. Assert connector call sequences and final state for both.
- [ ] **Step 2:** FAIL until all phases wired. **Step 3:** Fix wiring. **Step 4:** PASS. **Step 5:** Commit.

### Task 11.2: Go→Swift mapping doc + parity checklist + README pointer

**Files:** Create `docs/go-to-swift-map.md`; modify `README.md` (add a "Swift rewrite (in progress)" section pointing to the spec, plan, and build docs).

- [ ] **Step 1:** Write the file-by-file map (every Go source → Swift target) and copy the spec's parity checklist. **Step 2:** Update README. **Step 3:** Commit.

### Task 11.3: Full test sweep + static build attempt + open draft PR

- [ ] **Step 1:** `cd swift && swift test` (native + in docker) → all green; record output.
- [ ] **Step 2:** Attempt `swift build --swift-sdk aarch64-swift-linux-musl -c release`; if it links, note binary size + `file` output in `docs/swift-build.md`; if BoringSSL/musl blocks it, document the state and the curl-fallback path (still ships a static binary for the non-URL paths).
- [ ] **Step 3:** `git push -u origin feature/swift-rewrite`.
- [ ] **Step 4:** Open a **draft** PR into `main` with: summary, the parity checklist (unchecked items = hardware-only), "not yet validated on Jetson" caveat, and `swift test` output. Use `gh pr create --draft --base main`. PR body ends with the required Claude Code footer.
- [ ] **Step 5:** Commit any final doc tweaks.

---

## Self-review notes (author)

- **Spec coverage:** runtime/static-musl (0.2, 10.2, 11.3) · deps (0.1, 2.1, 7.1, 10.2) · package split Tar/Zstd/WendyLog (1.1–1.3, 7.1) · module map (all phases) · connector polymorphism + registry (5.1) · error/exit model (`ExitCoded` 5.1/3.1, mapping 10.1) · JSON via IkigaJSON+schema + deterministic order (2.1, 2.2) · platform seams/testability (1.5, all engine/connector tests) · logging/progress (7.1) · download+curl fallback (10.2) · parity checklist (11.2) · Go tree kept (Global Constraints) · draft PR (11.3). No gaps found.
- **Placeholders:** none — each task cites concrete Go sources, exact Swift signatures, and concrete test assertions.
- **Type consistency:** `Slot`, `Connector`, `Engine` fields, `ExitCoded`, error enums, `ArtifactReader`/`PayloadStream`, `BlockDev.writeImage` signature, `Compression`, and `JSONCodec` names are used identically across tasks 1–11.
