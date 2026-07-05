import CLIError
import Connector
import Logging
import Model

// Commit, Rollback, the Switch verb, and the boot verifier — the
// post-reboot half of the update lifecycle (docs/cli-contract.md,
// docs/state-schema.md). Ports internal/engine/commit.go end to end; the
// ORDERING below (mark-failed-before-advisory-hooks, clearState-before-
// appendInstalled, confirm-vs-not-confirm in VerifyBoot) is safety-critical
// and must not be reshuffled.

private let logger = Logger(label: "wendyos-update")

/// `installed.json` is capped at this many entries. Ports
/// `installedHistoryCap` in internal/engine/commit.go.
let installedHistoryCap = 10

/// Ports `PlatformVerifyError`/the two ad hoc `fmt.Errorf`s at the top of
/// `Engine.Commit`, and `ErrNothingToCommit` (internal/engine/commit.go) —
/// unified into one `Error` type so `Engine.commit()` has a single thrown
/// type, with `Kind` distinguishing the three CLI-contract outcomes.
public struct CommitError: Error, Equatable, ExitCoded {
    public enum Kind: Equatable, Sendable {
        /// Ports `ErrNothingToCommit`: exit code 2 — NOT an error for
        /// callers (mirrors mender-update; wendy-agent special-cases it).
        case nothingToCommit
        /// Ports the plain `fmt.Errorf`s for `PhaseFailed`/`PhaseWritten`
        /// (and the `default:` unknown-phase case): exit code 1.
        case phaseFailed(String)
        /// Ports `PlatformVerifyError`: exit code 4 — the update reached
        /// commit but platform verification (or the health hook) failed;
        /// the deployment is marked failed and the caller should roll back.
        case platformVerify(String)
    }

    public let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public var exitCode: Int32 {
        switch kind {
        case .nothingToCommit: return 2
        case .platformVerify: return 4
        case .phaseFailed: return 1
        }
    }
}

/// Ports the plain `fmt.Errorf("nothing to roll back")` and the two
/// `%w`-wrapped messages in `Engine.Rollback`/`Engine.Switch`. Both verbs
/// map to CLI exit code 1 like every other generic Go error (main.go's
/// `exitCode` only special-cases `ErrNothingToCommit`/`PlatformVerifyError`/
/// `HookError`), so a single generic-message type covers both — ported as
/// two distinct types only so a caller can tell which verb failed without
/// string-matching.
public struct RollbackError: Error, Equatable, ExitCoded {
    public let message: String
    public var exitCode: Int32 { 1 }
}

public struct SwitchError: Error, Equatable, ExitCoded {
    public let message: String
    public var exitCode: Int32 { 1 }
}

/// Tells the caller whether a reboot is needed to finish the rollback
/// (true when we are currently running the rolled-back-from slot). Ports
/// `RollbackResult` in internal/engine/commit.go.
public struct RollbackResult: Sendable, Equatable {
    public let originSlot: Slot
    public let rebootRequired: Bool

    public init(originSlot: Slot, rebootRequired: Bool) {
        self.originSlot = originSlot
        self.rebootRequired = rebootRequired
    }
}

extension Engine {
    /// Finalizes a pending update after a healthy boot: confirm we are
    /// running the target slot, run platform verification, run the
    /// userspace health gate, mark the platform good, clear the pending
    /// state, record history. Ports `Engine.Commit` verbatim, including its
    /// ordering — see docs/state-schema.md's "Ordering rules".
    public func commit() async throws {
        guard let loaded = try loadState() else {
            throw CommitError(.nothingToCommit)
        }
        var st = loaded

        switch st.phase {
        case PhaseFailed:
            throw CommitError(.phaseFailed("pending update \(st.artifactName) is marked failed; run rollback"))
        case PhaseWritten:
            throw CommitError(.phaseFailed(
                "pending update \(st.artifactName) was written but never swapped; run rollback or mark-good"
            ))
        case PhaseSwapped:
            break // proceed
        default:
            throw CommitError(.phaseFailed("pending update has unknown phase \"\(st.phase)\""))
        }

        logger.info(
            "commit: finalizing pending update",
            metadata: [
                "artifact": "\(st.artifactName)", "version": "\(st.artifactVersion)",
                "target": "\(Slot(rawValue: st.targetSlot)?.description ?? "\(st.targetSlot)")",
            ]
        )

        let cur = try conn.currentSlot()
        let env = hookEnv(
            name: st.artifactName, version: st.artifactVersion,
            target: Slot(rawValue: st.targetSlot) ?? cur, cur: cur, blUpdate: st.bootloaderUpdate
        )

        if cur.rawValue != st.targetSlot {
            // The firmware fell back to the old slot — the new one never
            // produced a healthy boot.
            st.phase = PhaseFailed
            try saveState(st)
            await runAdvisoryHooks(HookOnFailure, env)
            throw CommitError(.platformVerify(
                "platform verification failed: running slot \(cur) but the update targeted slot " +
                    "\(st.targetSlot) (firmware fallback)"
            ))
        }
        logger.info("commit: running expected slot", metadata: ["slot": "\(cur)"])

        do {
            try conn.verifyPlatformUpdate(bootloaderUpdate: st.bootloaderUpdate)
        } catch {
            st.phase = PhaseFailed
            try saveState(st)
            await runAdvisoryHooks(HookOnFailure, env)
            throw CommitError(.platformVerify("platform verification failed: \(error)"))
        }

        // Userspace health gate (product-defined, network-independent):
        // /etc/wendyos-update/health.d/. The firmware checks above are the
        // baseline; these add product checks. A failure marks the
        // deployment failed (like a platform-verify failure) so a reboot
        // rolls back.
        do {
            try await runHooks(HookHealth, env)
        } catch {
            st.phase = PhaseFailed
            try saveState(st)
            await runAdvisoryHooks(HookOnFailure, env)
            throw error // rethrow the HookError itself: its exitCode is already 4
        }

        logger.info("commit: verification passed")

        // Housekeeping must not undo a successful update (the validated
        // reset-inactive-slot-status rule): log, don't fail.
        do {
            try conn.markGood()
        } catch {
            logger.warning("post-commit housekeeping failed", metadata: ["err": "\(error)"])
        }

        // Order per state-schema.md: clear state first, then history — a
        // crash in between loses only history, never safety.
        try clearState()
        do {
            try appendInstalled(InstalledEntry(
                artifactName: st.artifactName,
                artifactVersion: st.artifactVersion,
                committed: clock.nowUTCISO8601(),
                slot: st.targetSlot
            ))
        } catch {
            logger.warning("could not record install history", metadata: ["err": "\(error)"])
        }

        // post-commit hook: the update is finalized; failures here are
        // advisory (too late to undo a committed update) — products notify
        // cloud, etc.
        await runAdvisoryHooks(HookPostCommit, env)
        logger.info(
            "commit: done",
            metadata: ["artifact": "\(st.artifactName)", "slot": "\(Slot(rawValue: st.targetSlot)?.description ?? "\(st.targetSlot)")"]
        )
    }

    /// Abandons a pending update and swaps back to the origin slot.
    ///
    /// - Pre-reboot (still on the origin slot): unstage any platform
    ///   update, re-point the active slot at the running one. No reboot
    ///   needed.
    /// - Post-reboot (running the target slot): swap back. Reboot required.
    ///
    /// Ports `Engine.Rollback` verbatim.
    public func rollback() throws -> RollbackResult {
        guard let st = try loadState() else {
            throw RollbackError(message: "nothing to roll back")
        }

        let target = Slot(rawValue: st.targetSlot) ?? .a
        let origin = target.other

        let cur = try conn.currentSlot()
        logger.info(
            "rollback: reverting pending update",
            metadata: ["artifact": "\(st.artifactName)", "from": "\(target)", "to": "\(origin)"]
        )

        if cur == origin {
            // Pre-reboot rollback: disarm a staged-but-unprocessed platform
            // update before re-pointing the slot (no-op when nothing is
            // staged).
            try conn.abortPlatformUpdate()
            logger.info("rollback: disarmed any staged platform update")
        }
        try conn.swapSlot(origin, stagePlatformUpdate: false)
        try clearState()

        let rebootRequired = cur == target
        if rebootRequired {
            logger.info(
                "rolled back — reboot to return to the previous system",
                metadata: ["origin_slot": "\(origin)", "reboot_required": "true"]
            )
        } else {
            logger.info("rolled back", metadata: ["origin_slot": "\(origin)", "reboot_required": "false"])
        }
        return RollbackResult(originSlot: origin, rebootRequired: rebootRequired)
    }

    /// Makes the other slot active for the next boot WITHOUT installing an
    /// update — a permanent re-point (not a trial). The caller must reboot
    /// for it to take effect.
    ///
    /// Refuses while an update is pending: a switch would clobber the trial
    /// bookkeeping (commit or rollback that first).
    ///
    /// Ports `Engine.Switch` verbatim.
    public func `switch`(to target: Slot) throws {
        if let st = try loadState() {
            throw SwitchError(
                message: "an update is pending (\(st.artifactName), phase \(st.phase)); commit or rollback before switching"
            )
        }
        let cur = try conn.currentSlot()
        if target == cur {
            throw SwitchError(message: "already running slot \(cur)")
        }
        do {
            try conn.prepareTarget(target)
        } catch {
            throw SwitchError(message: "switch: prepare slot \(target): \(error)")
        }
        // If SwapSlot fails here the active slot is unchanged (we still
        // boot the current, committed slot), so there is no strand.
        do {
            try conn.swapSlot(target, stagePlatformUpdate: false)
        } catch {
            throw SwitchError(message: "switch: \(error)")
        }
        logger.info(
            "switched active slot — reboot to boot it",
            metadata: ["from": "\(cur)", "to": "\(target)", "reboot_required": "true"]
        )
    }

    /// The boot-time verifier behind wendyos-update-verify.service (internal
    /// verb, not part of the public CLI contract). If an update is pending
    /// and the platform flagged the boot — or we are not running the slot
    /// the update targeted — the deployment is marked failed so the
    /// auto-commit unit cannot finalize it. Always best-effort: it must
    /// never fail the boot.
    ///
    /// Ports `Engine.VerifyBoot` verbatim.
    public func verifyBoot() async throws {
        let loaded: State?
        do {
            loaded = try loadState()
        } catch {
            // State unreadable, but THIS boot reached the verifier: confirm
            // it, or a firmware boot-watchdog would reboot a working system
            // over a userspace bookkeeping problem.
            confirmBoot()
            throw error
        }

        guard var st = loaded, st.phase == PhaseSwapped else {
            // No trial in flight (or one already marked failed/written):
            // the running slot is the committed system — confirm the boot.
            confirmBoot()
            return
        }

        var failed = false
        var confirm = true
        if let compromised = try? conn.bootIsCompromised(), compromised {
            failed = true
            // The firmware flagged the slot we are RUNNING: do not confirm
            // — the retry countdown is what makes the firmware abandon it.
            confirm = false
            logger.warning("boot verifier: platform flagged a slot as unhealthy")
        }
        if let cur = try? conn.currentSlot(), cur.rawValue != st.targetSlot {
            failed = true
            // Fallback: we are running the known-good ORIGIN slot, not the
            // trial target. The deployment is dead, but this boot is fine —
            // it must be confirmed or the watchdog reboots the only
            // bootable system left.
            logger.warning(
                "boot verifier: firmware fallback detected",
                metadata: ["running": "\(cur)", "target": "\(Slot(rawValue: st.targetSlot)?.description ?? "\(st.targetSlot)")"]
            )
        }

        if confirm {
            confirmBoot()
        }

        if failed {
            logger.warning("boot verifier: marking pending deployment failed", metadata: ["artifact": "\(st.artifactName)"])
            st.phase = PhaseFailed
            try saveState(st)
            let cur = (try? conn.currentSlot()) ?? (Slot(rawValue: st.targetSlot) ?? .a) // best-effort, hook context only
            await runAdvisoryHooks(
                HookOnFailure,
                hookEnv(
                    name: st.artifactName, version: st.artifactVersion,
                    target: Slot(rawValue: st.targetSlot) ?? .a, cur: cur, blUpdate: st.bootloaderUpdate
                )
            )
            return
        }
        logger.info("boot verifier: pending update looks healthy", metadata: ["artifact": "\(st.artifactName)"])
    }

    /// Tells firmware with a boot-validation watchdog that this boot
    /// succeeded (`BootConfirmer`). A healthy trial boot is confirmed too:
    /// the watchdog cannot be left running across a manual-commit window,
    /// and post-userspace health remains commit/rollback's job. Best-effort:
    /// the verifier must never fail the boot. Ports `Engine.confirmBoot`.
    func confirmBoot() {
        guard let bc = conn as? BootConfirmer else { return }
        do {
            try bc.confirmBoot()
        } catch {
            logger.warning("boot verifier: could not confirm the boot to the firmware", metadata: ["err": "\(error)"])
            return
        }
        logger.info("boot verifier: confirmed boot to the firmware")
    }

    /// Records a committed artifact, capping the history. Ports
    /// `Engine.appendInstalled`.
    func appendInstalled(_ entry: InstalledEntry) throws {
        let path = installedPath()
        var history = InstalledHistory(history: [])
        if fs.exists(path), let data = try? fs.read(path), let decoded = try? JSONCodec.decodeInstalled(data) {
            // Corrupt/malformed history starts fresh, mirroring Go's
            // swallowed `json.Unmarshal` error.
            history = decoded
        }
        history.history.append(entry)
        if history.history.count > installedHistoryCap {
            history.history = Array(history.history.suffix(installedHistoryCap))
        }
        let bytes = JSONCodec.encodePretty(history.makeJSONObject())
        try fs.writeAtomic(path, bytes, mode: 0o644)
    }

    private func installedPath() -> String {
        stateDir.hasSuffix("/") ? "\(stateDir)installed.json" : "\(stateDir)/installed.json"
    }
}
