import AsyncHTTPClient
import CLIError
import Dispatch
import Foundation
import Glibc
import LinuxSys
import NIOCore
import Tar

// `install <url|path>`'s source resolver — ports `cmd/wendyos-update/
// main.go`'s `cmdInstall` HTTP(S)-vs-local branch, plus (Task 10.2's new
// scope) the streaming download itself: async-http-client with
// per-connection-stage timeouts and NO overall body deadline (a multi-GB
// rootfs image can legitimately take a long time to transfer; only a
// stalled/broken connection — caught by the stage timeouts below, not a
// wall clock over the whole transfer — should ever abort it).
//
// The crux this file solves: `ArtifactReader.open` (and, through it,
// `Engine.install`) pulls bytes via a SYNCHRONOUS closure
// (`TarReader`'s `(inout [UInt8], Int) throws -> Int`), but
// async-http-client only hands back the response body as an ASYNC
// sequence of `ByteBuffer`s. Bridging the two without buffering the whole
// payload needs two different waiting strategies on either side of a
// small bounded queue (`BoundedByteQueue`) — see its doc comment — and,
// critically, the code that calls the synchronous pull closure
// (`ArtifactReader.open` + `Engine.install`) must run on a dedicated
// `Thread`, never on Swift Concurrency's cooperative pool, since that
// pull closure blocks a real OS thread while waiting for network data
// (`runOnDedicatedThread`/`blockingRun`, below).

/// Thrown for any `http(s)://` source failure: a non-2xx response, a
/// connection/TLS/timeout error, or an in-flight cancellation
/// (Ctrl-C/SIGTERM). Every case maps to exit 1 — ports `cmdInstall`'s ad
/// hoc `fmt.Errorf("download: %w", err)` (main.go has no dedicated
/// download error type; every download failure is exit 1 there too).
struct DownloadError: Error, ExitCoded {
    let message: String
    var exitCode: Int32 { 1 }
}

extension DownloadError: CustomStringConvertible {
    var description: String { message }
}

/// Per-connection-stage timeouts, ported from main.go's
/// `installHTTPClient` (`httpDialTimeout` / `httpTLSHandshakeTimeout` /
/// `httpResponseHeaderTimeout` — 30s / 30s / 60s, `internal/http.
/// Transport`-level). AsyncHTTPClient's `Configuration.Timeout` doesn't
/// expose a TLS-handshake-specific knob the way Go's `http.Transport`
/// does — TLS negotiation happens inside the same connection-
/// establishment step as the TCP dial — so `connect` below bounds
/// dial+TLS combined at the dial budget, and `installRequestTimeout`
/// (passed to `execute(_:timeout:)`, which doesn't return until response
/// HEADERS arrive) bounds the whole "until headers arrive" phase at the
/// Go implementation's worst-case sum. Once `execute()` returns, no
/// further deadline applies anywhere in this file — body streaming is
/// intentionally unbounded, matching "NO overall body timeout".
let installHTTPClientConfiguration = HTTPClient.Configuration(
    timeout: .init(connect: .seconds(30))
)

/// `httpDialTimeout` + `httpTLSHandshakeTimeout` + `httpResponseHeaderTimeout`
/// — see `installHTTPClientConfiguration`'s doc comment.
let installRequestTimeout: TimeAmount = .seconds(30 + 30 + 60)

/// A resolved install source: the `TarReader` the pipeline pulls from,
/// plus a `teardown` the caller MUST run once the consumer (the
/// `ArtifactReader.open` + `Engine.install` pipeline) stops for ANY reason
/// — success, rejection, or thrown error.
///
/// Teardown matters because the consumer can legitimately stop long before
/// the whole (multi-GB) body is drained: `ArtifactReader.open` reads only
/// `manifest.json` (a few hundred bytes), after which `Engine.install` can
/// reject on a routine policy gate (wrong device, bad version, digest
/// mismatch) without ever pulling the payload. If nothing then tore down
/// the background HTTP producer, it would keep `push`-ing at network speed,
/// fill the bounded queue, and suspend forever on a queue no one drains —
/// leaking the `Task` and the HTTP connection. `teardown` cancels the
/// producer and fails the queue so any in-flight `push` returns at once.
/// `producer` is exposed so a test can `await` its completion and prove no
/// leak; it's `nil` for a local source (no background task).
struct ArtifactSource: Sendable {
    let tar: TarReader
    let producer: Task<Void, Never>?
    let teardown: @Sendable () -> Void
}

/// Resolves `src` into an `ArtifactSource` streaming its bytes: a local
/// path (or `-` for stdin) opens synchronously exactly as Task 10.1 left
/// it; an `http(s)://` URL streams the response body through `httpClient`.
func openArtifactSource(_ src: String, httpClient: HTTPClient) async throws -> ArtifactSource {
    if src.hasPrefix("http://") || src.hasPrefix("https://") {
        return try await openHTTPTarReader(src, httpClient: httpClient)
    }
    return ArtifactSource(tar: try openLocalTarReader(src), producer: nil, teardown: {})
}

/// Task 10.1's local-file/stdin `TarReader` wiring, unchanged: a single
/// `LinuxSys.read` pull closure over an already-open fd (`0` for `-`).
func openLocalTarReader(_ path: String) throws -> TarReader {
    let fd: Int32 = path == "-" ? 0 : try LinuxSys.openRead(path)
    return TarReader { into, max in
        var chunk = [UInt8](repeating: 0, count: max)
        let n = try chunk.withUnsafeMutableBytes { ptr in try LinuxSys.read(fd, ptr) }
        into = n == max ? chunk : Array(chunk[0..<n])
        return n
    }
}

/// Streams an `http(s)://` source: issues the GET, validates the status
/// (a non-200 throws immediately — nothing is ever handed to the caller
/// in that case), then wires the response body into a `TarReader` backed
/// by a `BoundedByteQueue`. Ctrl-C/SIGTERM cancellation is armed here on
/// `sharedInstallCancellation`, which cancels the unstructured `Task` this
/// function spawns to drain the body — cancelling it fails the queue, so
/// the sync `read` closure throws and the in-flight write aborts rather
/// than silently finishing into a truncated artifact. The caller
/// (`Command.swift`'s `Install.run()`) disarms it once the whole install
/// pipeline (successful or not) is done.
func openHTTPTarReader(_ url: String, httpClient: HTTPClient) async throws -> ArtifactSource {
    let request = HTTPClientRequest(url: url)
    let response: HTTPClientResponse
    do {
        response = try await httpClient.execute(request, timeout: installRequestTimeout)
    } catch {
        throw DownloadError(message: "download: \(url): \(error)")
    }
    guard response.status == .ok else {
        throw DownloadError(message: "download: \(url) returned \(response.status)")
    }

    let queue = BoundedByteQueue()
    let body = response.body
    let drainTask = Task {
        do {
            try await withTaskCancellationHandler {
                for try await buffer in body {
                    try Task.checkCancellation()
                    await queue.push(Array(buffer.readableBytesView))
                }
                queue.finish()
            } onCancel: {
                queue.fail(DownloadError(message: "download: \(url): cancelled"))
            }
        } catch {
            queue.fail(DownloadError(message: "download: \(url): \(error)"))
        }
    }
    sharedInstallCancellation.arm(cancelling: drainTask)

    let tar = TarReader { into, max in try queue.pull(into: &into, max: max) }
    // The consumer (this `tar`, driven by `ArtifactReader.open` +
    // `Engine.install`) can stop pulling well before the body is drained
    // — a routine manifest/device/digest rejection reads only the manifest
    // and never touches the payload. `teardown` (run unconditionally by
    // `Install.run()` once the pipeline finishes for ANY reason) cancels
    // the producer and fails the queue, so a `push` suspended on a full
    // queue returns at once instead of hanging forever on a queue that
    // will never be drained again. Both steps are idempotent.
    let teardown: @Sendable () -> Void = {
        drainTask.cancel()
        queue.fail(DownloadError(message: "download: \(url): consumer stopped before body fully read"))
    }
    return ArtifactSource(tar: tar, producer: drainTask, teardown: teardown)
}

/// A small, bounded, thread-safe byte queue bridging an async producer
/// (the HTTP response body, consumed on Swift Concurrency's cooperative
/// pool) to a synchronous consumer (`TarReader`'s pull closure, invoked
/// from a dedicated `Thread` — see `runOnDedicatedThread`) without ever
/// buffering the whole (possibly multi-GB) payload in memory.
///
/// The two sides deliberately use different waiting strategies:
///  - the CONSUMER blocks with a real OS-thread wait (`NSCondition
///    .wait()`) when the queue is empty. Safe ONLY because every caller
///    of `pull` runs on a dedicated, non-cooperative-pool `Thread`.
///  - the PRODUCER suspends (`await withCheckedContinuation`, not a
///    thread block) when the queue is at capacity, since `push` runs
///    inside a normal `Task` on the cooperative pool — blocking a pool
///    thread there would risk starving the very executor that's supposed
///    to keep draining the queue (exactly the anti-pattern this whole
///    bridge exists to avoid).
final class BoundedByteQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var chunks: [[UInt8]] = []
    private var buffered = 0
    private let capacity: Int
    private var finished = false
    private var failure: Error?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(capacity: Int = 4 << 20) {
        self.capacity = capacity
    }

    /// The outcome of one `tryAppend` attempt.
    private enum AppendResult {
        /// The chunk was enqueued.
        case appended
        /// The queue is at capacity — `push` should suspend and retry.
        case full
        /// The queue is finished/failed — `push` should stop entirely
        /// (dropping the chunk is correct: on a clean EOF the producer is
        /// done anyway, and on failure/cancellation the whole transfer is
        /// being abandoned).
        case terminal
    }

    /// PRODUCER: appends `chunk`, suspending the calling `Task` (never
    /// blocking its thread) while the queue is already full, and returning
    /// immediately once the queue reaches a terminal state (EOF/failure/
    /// cancellation) so a `fail()` that lands while this `push` is
    /// suspended can never leave it re-registering on a queue no one will
    /// ever drain again.
    func push(_ chunk: [UInt8]) async {
        guard !chunk.isEmpty else { return }
        while true {
            switch tryAppend(chunk) {
            case .appended, .terminal:
                return
            case .full:
                break
            }
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                condition.lock()
                // Re-check terminal state AND capacity under the lock:
                // either a `fail()`/`finish()` or a drain may have landed
                // in the window between `tryAppend`'s unlock and this
                // lock. Resume immediately in both cases rather than
                // registering a waiter — the enclosing loop then re-runs
                // `tryAppend`, which returns `.terminal` (→ `push` returns)
                // or `.appended`. Only a still-full, still-live queue
                // parks a waiter.
                if finished || failure != nil || buffered < capacity {
                    condition.unlock()
                    resume.resume()
                } else {
                    waiters.append(resume)
                    condition.unlock()
                }
            }
        }
    }

    /// Synchronous helper behind `push`: `NSCondition`'s
    /// `lock`/`unlock`/`signal` are unavailable directly inside an
    /// `async` function body (a Swift concurrency-safety guard against
    /// holding a lock across a suspension point) — this plain,
    /// non-`async` function is exempt, since it never suspends while
    /// holding the lock.
    private func tryAppend(_ chunk: [UInt8]) -> AppendResult {
        condition.lock()
        defer { condition.unlock() }
        if finished || failure != nil { return .terminal }
        guard buffered < capacity else { return .full }
        chunks.append(chunk)
        buffered += chunk.count
        condition.signal()
        return .appended
    }

    /// PRODUCER: signals a clean end-of-stream.
    func finish() {
        condition.lock()
        finished = true
        let woken = waiters
        waiters.removeAll()
        condition.signal()
        condition.unlock()
        // Defensive: with a single producer there is no `push` suspended
        // when `finish` runs (it's the producer itself, past its own
        // loop), but waking any waiter costs nothing and keeps the
        // terminal-state contract — a woken `push` re-checks and returns.
        for w in woken { w.resume() }
    }

    /// PRODUCER (or an external canceller): signals an abnormal end — the
    /// consumer's current or next `pull` throws `error` once whatever was
    /// already buffered has been drained.
    func fail(_ error: Error) {
        condition.lock()
        if failure == nil { failure = error }
        finished = true
        let woken = waiters
        waiters.removeAll()
        condition.signal()
        condition.unlock()
        for w in woken { w.resume() }
    }

    /// CONSUMER (the `TarReader` pull closure): blocks the CALLING
    /// THREAD — which must be a dedicated `Thread`, never a
    /// Swift-concurrency cooperative-pool thread — until at least one
    /// byte is available, EOF, or failure.
    func pull(into buffer: inout [UInt8], max: Int) throws -> Int {
        condition.lock()
        while chunks.isEmpty && !finished {
            condition.wait()
        }
        if chunks.isEmpty {
            let err = failure
            condition.unlock()
            if let err { throw err }
            return 0
        }

        var out = [UInt8]()
        out.reserveCapacity(max)
        while out.count < max, !chunks.isEmpty {
            let need = max - out.count
            if chunks[0].count <= need {
                let piece = chunks.removeFirst()
                buffered -= piece.count
                out.append(contentsOf: piece)
            } else {
                out.append(contentsOf: chunks[0][0..<need])
                chunks[0].removeFirst(need)
                buffered -= need
            }
        }
        var toResume: [CheckedContinuation<Void, Never>] = []
        if buffered < capacity, !waiters.isEmpty {
            toResume = waiters
            waiters.removeAll()
        }
        condition.unlock()
        for w in toResume { w.resume() }

        buffer = out
        return out.count
    }
}

/// Runs `body` — a synchronous, throwing closure — on a dedicated OS
/// `Thread` that Swift Concurrency's cooperative pool doesn't own,
/// bridging its result back to the calling async context via a
/// `CheckedContinuation`. `install`'s HTTP source needs this: `body`
/// calls `ArtifactReader.open`/`Engine.install`, which pull bytes through
/// a `TarReader` closure backed by `BoundedByteQueue` — a closure whose
/// consumer side blocks a REAL thread while waiting for the async HTTP
/// body task to fill it (see that type's doc comment for why). Running
/// `body` on the cooperative pool instead would risk that blocking wait
/// starving the pool of the very worker the producer `Task` needs to run
/// on to unblock it.
func runOnDedicatedThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let thread = Thread {
            do {
                continuation.resume(returning: try body())
            } catch {
                continuation.resume(throwing: error)
            }
        }
        // The install pipeline's own call stack (tar parsing, hashing,
        // block writes) is unremarkable in depth, but a generous stack
        // avoids ever making that this bridge's problem.
        thread.stackSize = 4 << 20
        thread.start()
    }
}

/// Calls an `async throws` operation from a plain (non-cooperative-pool)
/// thread and blocks THAT thread until it completes — only safe to call
/// from a thread the Swift Concurrency runtime doesn't own (i.e. from
/// inside a `runOnDedicatedThread` body), since the blocking wait here is
/// a real `DispatchSemaphore.wait()`.
func blockingRun<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = OutcomeBox<T>()
    Task {
        do {
            box.outcome = .success(try await operation())
        } catch {
            box.outcome = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.outcome!.get()
}

/// Plain mutable box handing a `Task`'s result back to `blockingRun`'s
/// synchronous caller. `@unchecked Sendable`: written exactly once, by
/// the `Task` above, strictly before its `semaphore.signal()` — which
/// happens-before `blockingRun`'s `semaphore.wait()` returns and reads
/// it, so there is no concurrent access despite crossing threads.
private final class OutcomeBox<T>: @unchecked Sendable {
    var outcome: Result<T, Error>?
}

/// Ctrl-C (`SIGINT`) / `systemctl stop` (`SIGTERM`) during `install
/// <url>`'s streaming download must abort the in-flight read rather than
/// let it silently run to completion (or hang forever on a wedged
/// connection with no data and no error). `DispatchSourceSignal` is the
/// async-signal-safety-correct way to observe a signal from Swift: the
/// raw signal is set to `SIG_IGN` (so it doesn't also invoke the
/// default/kill disposition) and `Dispatch`'s libdispatch machinery
/// delivers the event to `setEventHandler`'s closure on an ordinary
/// queue, not from inside a restricted signal-handler context.
///
/// One process-wide instance: `wendyos-update` runs exactly one verb per
/// invocation, so there is only ever at most one in-flight download to
/// cancel. `arm`/`disarm` restore the signal's PRIOR disposition rather
/// than leaving it permanently `SIG_IGN`-ed, so a signal arriving well
/// outside any `install <url>` call (there isn't a legitimate case for
/// that in this one-shot CLI, but belt-and-suspenders) behaves normally.
final class InstallCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var sigint: DispatchSourceSignal?
    private var sigterm: DispatchSourceSignal?
    private var previousSIGINT: (@convention(c) (Int32) -> Void)?
    private var previousSIGTERM: (@convention(c) (Int32) -> Void)?

    func arm(cancelling task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard sigint == nil else { return } // already armed for this process's one download
        previousSIGINT = signal(SIGINT, SIG_IGN)
        previousSIGTERM = signal(SIGTERM, SIG_IGN)

        let onSignal: () -> Void = { task.cancel() }
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        intSource.setEventHandler(handler: onSignal)
        termSource.setEventHandler(handler: onSignal)
        intSource.resume()
        termSource.resume()
        sigint = intSource
        sigterm = termSource
    }

    func disarm() {
        lock.lock()
        defer { lock.unlock() }
        sigint?.cancel()
        sigterm?.cancel()
        sigint = nil
        sigterm = nil
        if let previousSIGINT { signal(SIGINT, previousSIGINT) }
        if let previousSIGTERM { signal(SIGTERM, previousSIGTERM) }
        previousSIGINT = nil
        previousSIGTERM = nil
    }
}

/// One per process — see `InstallCancellation`'s doc comment.
let sharedInstallCancellation = InstallCancellation()
