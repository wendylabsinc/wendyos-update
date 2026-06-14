package engine

// Commit, Rollback, and the boot verifier — the post-reboot half of the
// update lifecycle (docs/cli-contract.md, docs/state-schema.md).

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"github.com/wendylabsinc/wendy-os-update/internal/connector"
)

// ErrNothingToCommit maps to CLI exit code 2 — NOT an error for callers
// (mirrors mender-update; wendy-agent special-cases it).
var ErrNothingToCommit = errors.New("nothing to commit")

// PlatformVerifyError maps to CLI exit code 4: the update reached commit
// but platform verification failed; the deployment is marked failed and
// the caller should run rollback.
type PlatformVerifyError struct{ Err error }

func (e *PlatformVerifyError) Error() string { return "platform verification failed: " + e.Err.Error() }
func (e *PlatformVerifyError) Unwrap() error { return e.Err }

// installedHistoryCap bounds installed.json (docs/state-schema.md).
const installedHistoryCap = 10

// Commit finalizes a pending update after a healthy boot:
// confirm we are running the target slot, run platform verification,
// mark the platform good, clear the pending state, record history.
func (e *Engine) Commit() error {
	st, err := e.LoadState()
	if err != nil {
		return err
	}
	if st == nil {
		return ErrNothingToCommit
	}

	switch st.Phase {
	case PhaseFailed:
		return fmt.Errorf("pending update %s is marked failed; run rollback", st.ArtifactName)
	case PhaseWritten:
		return fmt.Errorf("pending update %s was written but never swapped; run rollback or mark-good", st.ArtifactName)
	case PhaseSwapped:
		// proceed
	default:
		return fmt.Errorf("pending update has unknown phase %q", st.Phase)
	}

	slog.Info("commit: finalizing pending update",
		"artifact", st.ArtifactName, "version", st.ArtifactVersion,
		"target", connector.Slot(st.TargetSlot).String())

	cur, err := e.Conn.CurrentSlot()
	if err != nil {
		return err
	}
	env := e.hookEnv(st.ArtifactName, st.ArtifactVersion, connector.Slot(st.TargetSlot), cur, st.BootloaderUpdate)
	if int(cur) != st.TargetSlot {
		// The firmware fell back to the old slot — the new one never
		// produced a healthy boot.
		st.Phase = PhaseFailed
		if serr := e.SaveState(st); serr != nil {
			return serr
		}
		e.runAdvisoryHooks(HookOnFailure, env)
		return &PlatformVerifyError{Err: fmt.Errorf("running slot %s but the update targeted slot %d (firmware fallback)", cur, st.TargetSlot)}
	}
	slog.Info("commit: running expected slot", "slot", cur.String())

	if err := e.Conn.VerifyPlatformUpdate(st.BootloaderUpdate); err != nil {
		st.Phase = PhaseFailed
		if serr := e.SaveState(st); serr != nil {
			return serr
		}
		e.runAdvisoryHooks(HookOnFailure, env)
		return &PlatformVerifyError{Err: err}
	}

	// Userspace health gate (product-defined, network-independent):
	// /etc/wendyos-update/health.d/. The firmware checks above are the
	// baseline; these add product checks. A failure marks the deployment
	// failed (like a platform-verify failure) so a reboot rolls back.
	if err := e.runHooks(HookHealth, env); err != nil {
		st.Phase = PhaseFailed
		if serr := e.SaveState(st); serr != nil {
			return serr
		}
		e.runAdvisoryHooks(HookOnFailure, env)
		return err
	}

	slog.Info("commit: verification passed")

	// Housekeeping must not undo a successful update (the validated
	// reset-inactive-slot-status rule): log, don't fail.
	if err := e.Conn.MarkGood(); err != nil {
		slog.Warn("post-commit housekeeping failed", "err", err)
	}

	// Order per state-schema.md: clear state first, then history —
	// a crash in between loses only history, never safety.
	if err := e.ClearState(); err != nil {
		return err
	}
	if err := e.appendInstalled(InstalledEntry{
		ArtifactName:    st.ArtifactName,
		ArtifactVersion: st.ArtifactVersion,
		Committed:       time.Now().UTC(),
		Slot:            st.TargetSlot,
	}); err != nil {
		slog.Warn("could not record install history", "err", err)
	}
	// post-commit hook: the update is finalized; failures here are advisory
	// (too late to undo a committed update) — products notify cloud, etc.
	e.runAdvisoryHooks(HookPostCommit, env)
	slog.Info("commit: done", "artifact", st.ArtifactName, "slot", connector.Slot(st.TargetSlot).String())
	return nil
}

// RollbackResult tells the caller whether a reboot is needed to finish
// the rollback (true when we are currently running the rolled-back-from
// slot).
type RollbackResult struct {
	OriginSlot     connector.Slot `json:"origin_slot"`
	RebootRequired bool           `json:"reboot_required"`
}

// Rollback abandons a pending update and swaps back to the origin slot.
//
//   - Pre-reboot (still on the origin slot): unstage any platform update,
//     re-point the active slot at the running one. No reboot needed.
//   - Post-reboot (running the target slot): swap back. On Tegra the
//     chain coupling means a processed bootloader capsule is also rolled
//     back (the origin chain still carries the old bootloader). Reboot
//     required.
func (e *Engine) Rollback() (*RollbackResult, error) {
	st, err := e.LoadState()
	if err != nil {
		return nil, err
	}
	if st == nil {
		return nil, fmt.Errorf("nothing to roll back")
	}

	target := connector.Slot(st.TargetSlot)
	origin := target.Other()

	cur, err := e.Conn.CurrentSlot()
	if err != nil {
		return nil, err
	}
	slog.Info("rollback: reverting pending update",
		"artifact", st.ArtifactName, "from", target.String(), "to", origin.String())

	if cur == origin {
		// Pre-reboot rollback: disarm a staged-but-unprocessed platform
		// update before re-pointing the slot (no-op when nothing is staged).
		if err := e.Conn.AbortPlatformUpdate(); err != nil {
			return nil, err
		}
		slog.Info("rollback: disarmed any staged platform update")
	}
	if err := e.Conn.SwapSlot(origin, false); err != nil {
		return nil, err
	}
	if err := e.ClearState(); err != nil {
		return nil, err
	}

	res := &RollbackResult{OriginSlot: origin, RebootRequired: cur == target}
	if res.RebootRequired {
		slog.Info("rolled back — reboot to return to the previous system",
			"origin_slot", origin.String(), "reboot_required", true)
	} else {
		slog.Info("rolled back", "origin_slot", origin.String(), "reboot_required", false)
	}
	return res, nil
}

// VerifyBoot is the boot-time verifier behind wendyos-update-verify.service
// (internal verb, not part of the public CLI contract). If an update is
// pending and the platform flagged the boot — or we are not running the
// slot the update targeted — the deployment is marked failed so the
// auto-commit unit cannot finalize it. Always best-effort: it must never
// fail the boot.
func (e *Engine) VerifyBoot() error {
	st, err := e.LoadState()
	if err != nil || st == nil {
		return err
	}
	if st.Phase != PhaseSwapped {
		return nil
	}

	failed := false
	if compromised, err := e.Conn.BootIsCompromised(); err == nil && compromised {
		failed = true
		slog.Warn("boot verifier: platform flagged a slot as unhealthy")
	}
	if cur, err := e.Conn.CurrentSlot(); err == nil && int(cur) != st.TargetSlot {
		failed = true
		slog.Warn("boot verifier: firmware fallback detected",
			"running", cur.String(), "target", connector.Slot(st.TargetSlot).String())
	}

	if failed {
		slog.Warn("boot verifier: marking pending deployment failed", "artifact", st.ArtifactName)
		st.Phase = PhaseFailed
		if serr := e.SaveState(st); serr != nil {
			return serr
		}
		cur, _ := e.Conn.CurrentSlot() // best-effort, for hook context only
		e.runAdvisoryHooks(HookOnFailure, e.hookEnv(st.ArtifactName, st.ArtifactVersion, connector.Slot(st.TargetSlot), cur, st.BootloaderUpdate))
		return nil
	}
	slog.Info("boot verifier: pending update looks healthy", "artifact", st.ArtifactName)
	return nil
}

// appendInstalled records a committed artifact, capping the history.
func (e *Engine) appendInstalled(entry InstalledEntry) error {
	path := filepath.Join(e.StateDir, "installed.json")
	var hist InstalledHistory
	if data, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(data, &hist) // corrupt history starts fresh
	}
	hist.History = append(hist.History, entry)
	if len(hist.History) > installedHistoryCap {
		hist.History = hist.History[len(hist.History)-installedHistoryCap:]
	}
	data, err := json.MarshalIndent(&hist, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
