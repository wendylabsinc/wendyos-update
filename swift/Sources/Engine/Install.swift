import Artifact
import BlockDev
import CLIError
import Connector
import Logging
import Model
import PlatformIO
import Zstd

// The `install` verb (docs/cli-contract.md): validate -> write inactive
// slot -> verify -> persist state -> prepare target -> swap. It never
// reboots. Ports `Engine.Install` in internal/engine/engine.go end to end;
// the ORDERING below (especially verify-before-persisting-state, and the
// post-install unwind order) is power-cut safety-critical and must not be
// reshuffled — see docs/state-schema.md's "Ordering rules".

private let logger = Logger(label: "wendyos-update")

/// Reports a successful install (up to "reboot required"). Ports
/// `engine.InstallResult` in internal/engine/engine.go.
public struct InstallResult: Sendable {
    public let artifactName: String
    public let artifactVersion: String
    public let targetSlot: Slot
    public let bootloaderUpdate: Bool

    public init(artifactName: String, artifactVersion: String, targetSlot: Slot, bootloaderUpdate: Bool) {
        self.artifactName = artifactName
        self.artifactVersion = artifactVersion
        self.targetSlot = targetSlot
        self.bootloaderUpdate = bootloaderUpdate
    }
}

extension Engine {
    /// Runs the full install sequence over an already-opened artifact
    /// (the CLI/download task is responsible for streaming the source into
    /// an `ArtifactReader` — this layer only sequences policy checks,
    /// the write, verification, and the state transitions around it).
    /// Ports `Engine.Install` verbatim, including its ordering.
    public func install(_ reader: ArtifactReader, blockTarget: any BlockTarget) async throws -> InstallResult {
        // One update in flight at a time.
        if let inFlight = try loadState() {
            throw EngineError.updateInFlight(phase: inFlight.phase, artifact: inFlight.artifactName)
        }

        let manifest = reader.manifest
        logger.info(
            "install: artifact opened",
            metadata: [
                "artifact": "\(manifest.artifactName)", "version": "\(manifest.artifactVersion)",
                "bootloader_update": "\(manifest.bootloaderUpdate)",
            ]
        )

        // Policy gates.
        let devType = try deviceType()
        if !manifest.compatible(with: devType) {
            throw EngineError.rejected(
                "artifact targets [\(manifest.compatibleDevices.joined(separator: " "))], this device is \"\(devType)\""
            )
        }
        if !versionAtLeast(toolVersion, manifest.minToolVersion) {
            throw EngineError.rejected(
                "artifact requires tool >= \(manifest.minToolVersion), this is \(toolVersion)"
            )
        }
        logger.info("install: artifact accepted", metadata: ["device": "\(devType)"])

        // Resolve the target slot.
        let cur = try conn.currentSlot()
        let target = cur.other
        let dev = try conn.partition(for: target)

        // Connector preflight: refuse now if the platform cannot actually
        // carry out an A/B switch, so we don't download, write, and reboot
        // only to roll back at commit.
        if let preflighter = conn as? InstallPreflighter {
            do {
                try preflighter.preflightInstall()
            } catch {
                throw EngineError.rejected("\(error)")
            }
        }

        // Capacity pre-flight: reject up front (nothing written) rather
        // than failing mid-write at the partition boundary. Fail-open when
        // the capacity can't be read.
        if let capBytes = try? BlockDev.deviceCapacity(dev, target: blockTarget),
           capBytes > 0, manifest.payload.size > capBytes
        {
            throw EngineError.rejected(
                "rootfs payload is \(manifest.payload.size) bytes but target slot \(dev) holds only \(capBytes) " +
                    "bytes; the image is too large for the on-device A/B slot"
            )
        }

        // pre-install gate: products may refuse the update before anything
        // is written. A failure aborts the install with nothing changed.
        let env = hookEnv(
            name: manifest.artifactName, version: manifest.artifactVersion,
            target: target, cur: cur, blUpdate: manifest.bootloaderUpdate
        )
        try await runHooks(HookPreInstall, env)

        logger.info(
            "install: writing rootfs to inactive slot",
            metadata: [
                "current": "\(cur)", "target": "\(target)", "dev": "\(dev)",
                "size": "\(manifest.payload.size)",
            ]
        )

        // Stream the payload onto the inactive slot.
        let payloadStream: PayloadStream
        do {
            payloadStream = try reader.payload()
        } catch {
            throw EngineError.rejected("\(error)")
        }
        reportProgress("write", 0)

        guard let compression = Compression(rawValue: manifest.payload.compression) else {
            throw EngineError.rejected("unsupported payload.compression \"\(manifest.payload.compression)\"")
        }

        var lastPercent = -2
        let (written, digest) = try BlockDev.writeImage(
            to: dev,
            from: { buf, max in
                var chunk = [UInt8](repeating: 0, count: max)
                let n = try payloadStream.read(into: &chunk)
                buf = n == max ? chunk : Array(chunk[0..<n])
                return n
            },
            compression: compression,
            target: blockTarget,
            progress: { writtenSoFar in
                var percent = -1
                if manifest.payload.size > 0 {
                    percent = Int(writtenSoFar * 100 / manifest.payload.size)
                    if percent > 100 { percent = 100 }
                }
                if percent != lastPercent {
                    lastPercent = percent
                    self.reportProgress("write", percent)
                }
            }
        )

        // Verify BEFORE persisting any state (state-schema.md ordering).
        reportProgress("verify", -1)
        logger.info("install: verifying payload", metadata: ["written": "\(written)"])
        if manifest.payload.size > 0, written != manifest.payload.size {
            throw EngineError.rejected(
                "payload size mismatch: wrote \(written), manifest says \(manifest.payload.size)"
            )
        }
        do {
            try reader.verifyPayloadDigests(uncompressedSHA256: digest)
        } catch {
            throw EngineError.rejected("\(error)")
        }

        var state = State(
            schema: 1,
            phase: PhaseWritten,
            targetSlot: target.rawValue,
            artifactName: manifest.artifactName,
            artifactVersion: manifest.artifactVersion,
            payloadSHA256: manifest.payload.sha256,
            bootloaderUpdate: manifest.bootloaderUpdate,
            created: clock.nowUTCISO8601()
        )
        try saveState(state)

        // Make the slot bootable, then swap.
        try conn.prepareTarget(target) // on throw: state stays phase=written; rollback/mark-good recovers
        logger.info("install: activating target slot", metadata: ["target": "\(target)"])
        reportProgress("swap", -1)
        // Install swap: the connector inspects the freshly-written rootfs
        // and stages a platform update if it requests one.
        try conn.swapSlot(target, stagePlatformUpdate: true) // on throw: ditto

        state.phase = PhaseSwapped
        try saveState(state)

        // post-install hook (after the swap, before reboot). On failure,
        // unwind the staged update so the slot is left clean: drop any
        // staged platform update, re-point the active slot back to the
        // running one, clear state — in that exact order.
        do {
            try await runHooks(HookPostInstall, env)
        } catch {
            logger.warning("post-install hook failed; unwinding staged update", metadata: ["err": "\(error)"])
            do {
                try conn.abortPlatformUpdate()
            } catch {
                logger.warning("unwind: abort platform update", metadata: ["err": "\(error)"])
            }
            do {
                try conn.swapSlot(cur, stagePlatformUpdate: false)
            } catch {
                logger.warning("unwind: re-point active slot", metadata: ["err": "\(error)"])
            }
            do {
                try clearState()
            } catch {
                logger.warning("unwind: clear state", metadata: ["err": "\(error)"])
            }
            throw error
        }

        return InstallResult(
            artifactName: manifest.artifactName,
            artifactVersion: manifest.artifactVersion,
            targetSlot: target,
            bootloaderUpdate: manifest.bootloaderUpdate
        )
    }
}
