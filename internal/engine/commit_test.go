package engine

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// swappedState seeds a pending update: written to slot B, swapped.
func swappedState() *State {
	return &State{
		Schema:          1,
		Phase:           PhaseSwapped,
		TargetSlot:      1,
		ArtifactName:    "wendyos-image-test-1.2.3",
		ArtifactVersion: "1.2.3",
	}
}

func TestCommitNothingPending(t *testing.T) {
	e := testEngine(t, &fakeConn{cur: connector.SlotA})
	if err := e.Commit(); !errors.Is(err, ErrNothingToCommit) {
		t.Fatalf("want ErrNothingToCommit, got %v", err)
	}
}

func TestCommitHappyPath(t *testing.T) {
	f := &fakeConn{cur: connector.SlotB} // running the target slot
	e := testEngine(t, f)
	e.SaveState(swappedState())

	if err := e.Commit(); err != nil {
		t.Fatal(err)
	}
	if f.markGood != 1 {
		t.Fatal("MarkGood not called")
	}
	if st, _ := e.LoadState(); st != nil {
		t.Fatal("state not cleared")
	}
	// history recorded
	data, err := os.ReadFile(filepath.Join(e.StateDir, "installed.json"))
	if err != nil {
		t.Fatal(err)
	}
	var hist InstalledHistory
	json.Unmarshal(data, &hist)
	if len(hist.History) != 1 || hist.History[0].ArtifactVersion != "1.2.3" || hist.History[0].Slot != 1 {
		t.Fatalf("history: %+v", hist)
	}
}

func TestCommitDetectsFirmwareFallback(t *testing.T) {
	f := &fakeConn{cur: connector.SlotA} // fell back: NOT the target slot
	e := testEngine(t, f)
	e.SaveState(swappedState())

	err := e.Commit()
	var pv *PlatformVerifyError
	if !errors.As(err, &pv) {
		t.Fatalf("want PlatformVerifyError, got %v", err)
	}
	st, _ := e.LoadState()
	if st == nil || st.Phase != PhaseFailed {
		t.Fatalf("state after fallback: %+v", st)
	}
	if f.markGood != 0 {
		t.Fatal("MarkGood must not run on fallback")
	}
}

func TestCommitPlatformVerifyFailure(t *testing.T) {
	f := &fakeConn{cur: connector.SlotB, verifyErr: errors.New("ESRT status 6163")}
	e := testEngine(t, f)
	e.SaveState(swappedState())

	err := e.Commit()
	var pv *PlatformVerifyError
	if !errors.As(err, &pv) {
		t.Fatalf("want PlatformVerifyError, got %v", err)
	}
	st, _ := e.LoadState()
	if st == nil || st.Phase != PhaseFailed {
		t.Fatalf("state: %+v", st)
	}
}

func TestCommitRefusesFailedPhase(t *testing.T) {
	e := testEngine(t, &fakeConn{cur: connector.SlotB})
	st := swappedState()
	st.Phase = PhaseFailed
	e.SaveState(st)

	err := e.Commit()
	if err == nil || errors.Is(err, ErrNothingToCommit) {
		t.Fatalf("failed phase must be a hard error: %v", err)
	}
}

func TestRollbackPreReboot(t *testing.T) {
	// Still on the origin slot (A); update targeted B.
	f := &fakeConn{cur: connector.SlotA}
	e := testEngine(t, f)
	e.SaveState(swappedState())

	res, err := e.Rollback()
	if err != nil {
		t.Fatal(err)
	}
	if res.OriginSlot != connector.SlotA || res.RebootRequired {
		t.Fatalf("pre-reboot result: %+v (want origin A, reboot_required false)", res)
	}
	if f.aborted != 1 {
		t.Fatal("AbortPlatformUpdate not called on pre-reboot rollback")
	}
	if len(f.swapped) != 1 || f.swapped[0] != connector.SlotA {
		t.Fatalf("swap calls: %v", f.swapped)
	}
	if st, _ := e.LoadState(); st != nil {
		t.Fatal("state not cleared")
	}
}

func TestRollbackPostReboot(t *testing.T) {
	// Running the target slot (B); roll back to A.
	f := &fakeConn{cur: connector.SlotB}
	e := testEngine(t, f)
	e.SaveState(swappedState())

	res, err := e.Rollback()
	if err != nil {
		t.Fatal(err)
	}
	if res.OriginSlot != connector.SlotA || !res.RebootRequired {
		t.Fatalf("post-reboot result: %+v (want origin A, reboot_required true)", res)
	}
	if f.aborted != 0 {
		t.Fatal("AbortPlatformUpdate must not run post-reboot (capsule already consumed)")
	}
	if len(f.swapped) != 1 || f.swapped[0] != connector.SlotA {
		t.Fatalf("swap calls: %v", f.swapped)
	}
	if st, _ := e.LoadState(); st != nil {
		t.Fatal("state not cleared")
	}
}

func TestRollbackNothingPending(t *testing.T) {
	e := testEngine(t, &fakeConn{cur: connector.SlotA})
	if _, err := e.Rollback(); err == nil {
		t.Fatal("expected error with nothing pending")
	}
}

func TestVerifyBootMarksFallbackFailed(t *testing.T) {
	f := &fakeConn{cur: connector.SlotA} // update targeted B, we run A
	e := testEngine(t, f)
	e.SaveState(swappedState())

	if err := e.VerifyBoot(); err != nil {
		t.Fatal(err)
	}
	st, _ := e.LoadState()
	if st == nil || st.Phase != PhaseFailed {
		t.Fatalf("state: %+v", st)
	}
}

func TestVerifyBootMarksCompromisedFailed(t *testing.T) {
	f := &fakeConn{cur: connector.SlotB, compromised: true}
	e := testEngine(t, f)
	e.SaveState(swappedState())

	if err := e.VerifyBoot(); err != nil {
		t.Fatal(err)
	}
	st, _ := e.LoadState()
	if st == nil || st.Phase != PhaseFailed {
		t.Fatalf("state: %+v", st)
	}
}

func TestVerifyBootHealthyNoop(t *testing.T) {
	f := &fakeConn{cur: connector.SlotB}
	e := testEngine(t, f)
	e.SaveState(swappedState())

	if err := e.VerifyBoot(); err != nil {
		t.Fatal(err)
	}
	st, _ := e.LoadState()
	if st == nil || st.Phase != PhaseSwapped {
		t.Fatalf("healthy boot must not change state: %+v", st)
	}
}

func TestVerifyBootNoPending(t *testing.T) {
	e := testEngine(t, &fakeConn{cur: connector.SlotA})
	if err := e.VerifyBoot(); err != nil {
		t.Fatal(err)
	}
}

// --- per-boot confirm (connector.BootConfirmer) ---
//
// On boards where the firmware arms a boot-validation watchdog every boot
// (Jetson rootfs A/B: UEFI reboots the SoC unless userspace confirms the boot
// — stock L4T's nv_update_verifier.service, which WendyOS does not ship), the
// verify unit must confirm every boot that reaches it. A boot that dies
// earlier is never confirmed, so the watchdog + retry budget still deliver
// firmware fallback; post-userspace health remains commit/rollback's job.

// No pending update — the everyday boot — must be confirmed, or the watchdog
// reboots a perfectly healthy system every few minutes.
func TestVerifyBootConfirmsNoPending(t *testing.T) {
	f := &fakeConn{cur: connector.SlotA}
	e := testEngine(t, f)
	if err := e.VerifyBoot(); err != nil {
		t.Fatal(err)
	}
	if f.confirmed != 1 {
		t.Fatalf("healthy no-pending boot not confirmed to the firmware (confirmed=%d)", f.confirmed)
	}
}

// A healthy trial boot (running the target slot, not compromised) is also
// confirmed: the firmware watchdog cannot be left running across a manual
// commit window. Rollback stays possible afterwards via the explicit verbs.
func TestVerifyBootConfirmsHealthyTrial(t *testing.T) {
	f := &fakeConn{cur: connector.SlotB}
	e := testEngine(t, f)
	e.SaveState(swappedState())
	if err := e.VerifyBoot(); err != nil {
		t.Fatal(err)
	}
	if f.confirmed != 1 {
		t.Fatalf("healthy trial boot not confirmed (confirmed=%d)", f.confirmed)
	}
}

// A compromised boot must NOT be confirmed — the retry countdown is the
// mechanism that makes the firmware abandon this slot.
func TestVerifyBootNoConfirmWhenCompromised(t *testing.T) {
	f := &fakeConn{cur: connector.SlotB, compromised: true}
	e := testEngine(t, f)
	e.SaveState(swappedState())
	if err := e.VerifyBoot(); err != nil {
		t.Fatal(err)
	}
	if f.confirmed != 0 {
		t.Fatalf("compromised boot was confirmed (confirmed=%d)", f.confirmed)
	}
}

// Firmware fallback (running the origin, not the trial target): the pending
// deployment is marked failed, but the slot we are actually running is the
// known-good origin — it must be confirmed or the watchdog reboots the only
// bootable system we have left.
func TestVerifyBootConfirmsOriginAfterFallback(t *testing.T) {
	f := &fakeConn{cur: connector.SlotA} // update targeted B, we run A
	e := testEngine(t, f)
	e.SaveState(swappedState())
	if err := e.VerifyBoot(); err != nil {
		t.Fatal(err)
	}
	st, _ := e.LoadState()
	if st == nil || st.Phase != PhaseFailed {
		t.Fatalf("fallback not marked failed: %+v", st)
	}
	if f.confirmed != 1 {
		t.Fatalf("origin slot not confirmed after fallback (confirmed=%d)", f.confirmed)
	}
}

// A connector without the optional BootConfirmer (ubootenv: U-Boot's own
// bootcount machinery handles trials, no watchdog) is a clean no-op.
func TestVerifyBootNoConfirmerIsNoop(t *testing.T) {
	f := &fakeConn{cur: connector.SlotA}
	e := testEngine(t, f)
	e.Conn = plainConn{f}
	if err := e.VerifyBoot(); err != nil {
		t.Fatal(err)
	}
	if f.confirmed != 0 {
		t.Fatalf("ConfirmBoot reached through a connector that does not expose it (confirmed=%d)", f.confirmed)
	}
}
