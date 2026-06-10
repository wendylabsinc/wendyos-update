package engine

// Commit, Rollback, and the boot verifier — the post-reboot half of the
// update lifecycle (docs/cli-contract.md, docs/state-schema.md).

import (
	"encoding/json"
	"errors"
	"fmt"
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

	cur, err := e.Conn.CurrentSlot()
	if err != nil {
		return err
	}
	if int(cur) != st.TargetSlot {
		// The firmware fell back to the old slot — the new one never
		// produced a healthy boot.
		st.Phase = PhaseFailed
		if serr := e.SaveState(st); serr != nil {
			return serr
		}
		return &PlatformVerifyError{Err: fmt.Errorf("running slot %s but the update targeted slot %d (firmware fallback)", cur, st.TargetSlot)}
	}

	if err := e.Conn.VerifyPlatformUpdate(st.BootloaderUpdate); err != nil {
		st.Phase = PhaseFailed
		if serr := e.SaveState(st); serr != nil {
			return serr
		}
		return &PlatformVerifyError{Err: err}
	}

	// Userspace health gate (product-defined, network-independent):
	// /etc/wendy-update/health.d/. The firmware checks above are the
	// baseline; these add product checks. A failure marks the deployment
	// failed (like a platform-verify failure) so a reboot rolls back.
	if err := e.runHealthChecks(); err != nil {
		st.Phase = PhaseFailed
		if serr := e.SaveState(st); serr != nil {
			return serr
		}
		return err
	}

	// Housekeeping must not undo a successful update (the validated
	// reset-inactive-slot-status rule): log, don't fail.
	if err := e.Conn.MarkGood(); err != nil {
		fmt.Fprintf(os.Stderr, "wendy-update: warning: post-commit housekeeping failed: %v\n", err)
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
		fmt.Fprintf(os.Stderr, "wendy-update: warning: could not record install history: %v\n", err)
	}
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
func (e *Engine) Rollback() error {
	st, err := e.LoadState()
	if err != nil {
		return err
	}
	if st == nil {
		return fmt.Errorf("nothing to roll back")
	}

	target := connector.Slot(st.TargetSlot)
	origin := target.Other()

	cur, err := e.Conn.CurrentSlot()
	if err != nil {
		return err
	}

	if cur == origin {
		// Pre-reboot rollback: a staged-but-unprocessed platform update
		// must be disarmed before re-pointing the slot.
		if err := e.Conn.AbortPlatformUpdate(); err != nil {
			return err
		}
	}
	if err := e.Conn.SwapSlot(origin, false); err != nil {
		return err
	}
	if err := e.ClearState(); err != nil {
		return err
	}

	res := &RollbackResult{OriginSlot: origin, RebootRequired: cur == target}
	line, _ := json.Marshal(map[string]any{
		"phase":           "rollback",
		"origin_slot":     res.OriginSlot.String(),
		"reboot_required": res.RebootRequired,
	})
	e.emitRaw(string(line))
	if res.RebootRequired {
		fmt.Fprintln(os.Stderr, "wendy-update: rolled back — reboot to return to the previous system")
	}
	return nil
}

// emitRaw lets lifecycle verbs reuse the CLI's stdout JSON channel
// without knowing about it.
func (e *Engine) emitRaw(line string) {
	if e.Progress != nil {
		fmt.Println(line)
	}
}

// VerifyBoot is the boot-time verifier behind wendy-update-verify.service
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
		fmt.Fprintln(os.Stderr, "wendy-update: boot verifier: platform flagged a slot as unhealthy")
	}
	if cur, err := e.Conn.CurrentSlot(); err == nil && int(cur) != st.TargetSlot {
		failed = true
		fmt.Fprintf(os.Stderr, "wendy-update: boot verifier: running slot %s, update targeted slot %d (firmware fallback)\n", cur, st.TargetSlot)
	}

	if failed {
		st.Phase = PhaseFailed
		return e.SaveState(st)
	}
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
