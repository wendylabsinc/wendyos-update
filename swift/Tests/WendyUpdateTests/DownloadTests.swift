import AsyncHTTPClient
import Crypto
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

import Artifact
import Connector
import Engine
import Model
import PlatformIO
import PlatformIOTesting
import Tar

@testable import WendyUpdate

// Task 10.2: `install <url>`'s HTTP(S) streaming download. Exercises
// `openArtifactSource` end to end against a REAL (if tiny) in-process
// SwiftNIO HTTP/1.1 server on `127.0.0.1` — not a mock of AsyncHTTPClient —
// then feeds the resulting `TarReader` through `ArtifactReader.open` and
// `Engine.install` against fakes, exactly like `EngineTests/InstallTests
// .swift` does for an in-memory archive.

// MARK: - A minimal Connector fake

/// Just enough of `Connector`/`InstallPreflighter` for a happy-path
/// `Engine.install` to run to completion: current slot A, target B,
/// nothing scripted to fail. `EngineTests/FakeConnector.swift`'s much
/// richer fake isn't visible from this target (it's `internal` to
/// `EngineTests`), so this is a deliberately small, install-only stand-in.
private final class TestConnector: Connector, InstallPreflighter, @unchecked Sendable {
    let name = "test"
    var partitions: [Slot: String] = [.a: "/dev/fake-a", .b: "/dev/fake-b"]

    func currentSlot() throws -> Slot { .a }
    func partition(for s: Slot) throws -> String { partitions[s] ?? "" }
    func prepareTarget(_ s: Slot) throws {}
    func swapSlot(_ s: Slot, stagePlatformUpdate: Bool) throws {}
    func bootIsCompromised() throws -> Bool { false }
    func verifyPlatformUpdate(bootloaderUpdate: Bool) throws {}
    func abortPlatformUpdate() throws {}
    func markGood() throws {}
    func diagnostics(verbose: Bool) -> [String: String] { [:] }
    func slotStatus(_ s: Slot) -> SlotStatus { SlotStatus() }
    func systemStatus() -> [KV] { [] }
    func preflightInstall() throws {}
}

private func makeTestEngine(fs: any FileStore, toolVersion: String = "0.2.0") -> Engine {
    Engine(
        conn: TestConnector(),
        hooksDir: "/hooks",
        toolVersion: toolVersion,
        fs: fs,
        runner: FakeCommandRunner(),
        clock: FixedClock("2026-07-06T12:00:00Z"),
        env: MapEnv([:])
    )
}

private func makeBlockTarget(capacity: Int64 = 1 << 30) -> FakeBlockTarget {
    let target = FakeBlockTarget()
    target.capacities["/dev/fake-b"] = capacity
    return target
}

// MARK: - Building a `.wendy` archive in memory

private func hexEncode<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    var out = ""
    out.reserveCapacity(64)
    for byte in digest {
        out.append(hexDigitChar(byte >> 4))
        out.append(hexDigitChar(byte & 0x0F))
    }
    return out
}

private func hexDigitChar(_ nibble: UInt8) -> Character {
    nibble < 10
        ? Character(UnicodeScalar(UInt8(ascii: "0") + nibble))
        : Character(UnicodeScalar(UInt8(ascii: "a") + (nibble - 10)))
}

private func sha256Hex(_ bytes: [UInt8]) -> String {
    var h = SHA256()
    h.update(data: bytes)
    return hexEncode(h.finalize())
}

private final class ByteSink {
    private(set) var bytes: [UInt8] = []
    func write(_ chunk: [UInt8]) { bytes.append(contentsOf: chunk) }
}

/// A structurally valid v1 manifest with `payload.compression == "none"`,
/// matching `EngineTests/InstallTests.swift`'s fixture shape.
private func manifestJSON(
    artifactName: String, artifactVersion: String, compatibleDevices: [String],
    payloadSize: Int, sha256: String, bootloaderUpdate: Bool, minToolVersion: String
) -> [UInt8] {
    let devicesJSON = compatibleDevices.map { "\"\($0)\"" }.joined(separator: ", ")
    let json = """
        {
          "format_version": 1,
          "artifact_name": "\(artifactName)",
          "artifact_version": "\(artifactVersion)",
          "compatible_devices": [\(devicesJSON)],
          "payload": {
            "name": "payload",
            "size": \(payloadSize),
            "sha256": "\(sha256)",
            "compressed_sha256": "",
            "compression": "none"
          },
          "bootloader_update": \(bootloaderUpdate),
          "min_tool_version": "\(minToolVersion)"
        }
        """
    return Array(json.utf8)
}

private func buildWendyArchive(payload: [UInt8], artifactName: String, artifactVersion: String) throws -> [UInt8] {
    let manifestBytes = manifestJSON(
        artifactName: artifactName, artifactVersion: artifactVersion,
        compatibleDevices: ["jetson-agx-thor"], payloadSize: payload.count,
        sha256: sha256Hex(payload), bootloaderUpdate: false, minToolVersion: "0.1.0"
    )
    let sink = ByteSink()
    let writer = TarWriter { sink.write($0) }
    try writer.writeHeader(name: "manifest.json", size: Int64(manifestBytes.count), mode: 0o644)
    try writer.write(manifestBytes[...])
    try writer.writeHeader(name: "payload", size: Int64(payload.count), mode: 0o644)
    try writer.write(payload[...])
    try writer.finish()
    return sink.bytes
}

private func writeDeviceType(_ fs: FakeFileStore, board: String = "jetson-agx-thor") {
    try! fs.writeAtomic("/etc/wendyos/device-type", Array("BOARD=\(board)\n".utf8), mode: 0o644)
}

// MARK: - A tiny in-process HTTP/1.1 fixture server

/// Serves one fixed response body at `okPath` (status 200) and 404 for
/// every other path — enough to exercise both the happy path and the
/// non-200 error path against a REAL SwiftNIO server on `127.0.0.1`, no
/// TLS (plain `http://` to localhost, as the brief allows).
private final class FixtureHTTPServer {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    var port: Int { Int(channel.localAddress!.port!) }

    init(okPath: String, body: [UInt8]) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(FixtureHTTPHandler(okPath: okPath, body: body))
                }
            }
        channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
    }

    func shutdown() throws {
        try channel.close().wait()
        try group.syncShutdownGracefully()
    }
}

private final class FixtureHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let okPath: String
    private let body: [UInt8]
    private var uri = "/"

    init(okPath: String, body: [UInt8]) {
        self.okPath = okPath
        self.body = body
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            uri = head.uri
        case .body:
            break
        case .end:
            let matched = uri == okPath
            let status: HTTPResponseStatus = matched ? .ok : .notFound
            let responseBody = matched ? body : Array("not found".utf8)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "\(responseBody.count)")
            context.write(
                wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))),
                promise: nil
            )
            var buffer = context.channel.allocator.buffer(capacity: responseBody.count)
            buffer.writeBytes(responseBody)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

/// `HTTPClient.shutdown()` is `async` (its `syncShutdown()` sibling is
/// unavailable from an async context — it can block indefinitely), and
/// `defer` bodies can't contain an `await`, so every test needs this
/// try/finally-shaped wrapper instead of a plain `defer`.
private func withHTTPClient<T: Sendable>(
    _ body: (HTTPClient) async throws -> T
) async throws -> T {
    let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: installHTTPClientConfiguration)
    do {
        let result = try await body(client)
        try? await client.shutdown()
        return result
    } catch {
        try? await client.shutdown()
        throw error
    }
}

// MARK: - Tests

@Suite("install <url> streaming download")
struct DownloadTests {
    @Test func httpSourceStreamsAndInstallsEndToEnd() async throws {
        // 6 MiB: bigger than `BoundedByteQueue`'s default 4 MiB capacity,
        // so this genuinely exercises the producer's backpressure
        // suspend/resume path (`push` awaiting a continuation, then the
        // consumer's drain resuming it) rather than only ever taking the
        // "there's room" fast path a small payload would.
        let payload = [UInt8](repeating: 0x5A, count: 6 << 20)
        let archive = try buildWendyArchive(
            payload: payload,
            artifactName: "wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0",
            artifactVersion: "0.16.0"
        )
        let server = try FixtureHTTPServer(okPath: "/artifact.wendy", body: archive)
        defer { try? server.shutdown() }
        // `openArtifactSource`'s HTTP path arms `sharedInstallCancellation`
        // (a process-wide SIGINT/SIGTERM handler — see `Download.swift`)
        // for the duration of the download. Production's `Install.run()`
        // always disarms it in a `defer`; this test calls
        // `openArtifactSource` directly (bypassing that wrapper), so it
        // must disarm it itself — otherwise SIGINT/SIGTERM would stay
        // `SIG_IGN`-ed for the rest of this `swift test` process.
        defer { sharedInstallCancellation.disarm() }

        let result = try await withHTTPClient { httpClient in
            let tar = try await openArtifactSource(
                "http://127.0.0.1:\(server.port)/artifact.wendy", httpClient: httpClient
            )

            let fs = FakeFileStore()
            writeDeviceType(fs)
            let engine = makeTestEngine(fs: fs)
            let blockTarget = makeBlockTarget()

            let result = try await runOnDedicatedThread {
                let reader = try ArtifactReader.open(tar)
                return try blockingRun { try await engine.install(reader, blockTarget: blockTarget) }
            }

            #expect(result.artifactVersion == "0.16.0")
            #expect(result.targetSlot == .b)
            #expect(blockTarget.devices["/dev/fake-b"]?.written == payload)
            return result
        }

        // The exact stdout `done` JSON contract `install` emits.
        let bytes = JSONCodec.encodeCompact(makeInstallDoneJSON(result))
        #expect(
            String(decoding: bytes, as: UTF8.self)
                == #"{"artifact_name":"wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0","artifact_version":"0.16.0","bootloader_update":false,"percent":100,"phase":"done","reboot_required":true,"target_slot":"B"}"#
        )
    }

    @Test func nonOKStatusThrowsDownloadErrorMappingToExitOne() async throws {
        let server = try FixtureHTTPServer(okPath: "/artifact.wendy", body: [0x01])
        defer { try? server.shutdown() }

        try await withHTTPClient { httpClient in
            await #expect(throws: DownloadError.self) {
                _ = try await openArtifactSource(
                    "http://127.0.0.1:\(server.port)/missing.wendy", httpClient: httpClient
                )
            }

            do {
                _ = try await openArtifactSource(
                    "http://127.0.0.1:\(server.port)/missing.wendy", httpClient: httpClient
                )
                Issue.record("expected DownloadError")
            } catch let error as DownloadError {
                #expect(error.exitCode == 1)
                #expect(mapExit(error) == 1)
                #expect(error.description.contains("404"))
            } catch {
                Issue.record("expected DownloadError, got \(error)")
            }
        }
    }
}
