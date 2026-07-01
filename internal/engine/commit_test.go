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

// Commit must refuse when the state partition is configured (StateMount) but
// not actually mounted. An unmounted /data resolves to an empty shadow
// directory on the rootfs, so LoadState finds no state and Commit would return
// ErrNothingToCommit (exit 2 = success) — boot-complete.target is reached while
// the real pending update, sitting on the still-unmounted /data, is never
// finalized (and MarkGood never re-seeds the trial-boot retry budget, so the
// board rolls back and reboot-loops). Same silent-no-op class as the ubootenv
// /boot shadow-file trap (8bba71c). A plain directory shares its parent's
// st_dev, so it is not a mountpoint.
func TestCommitRefusesWhenStatePartitionUnmounted(t *testing.T) {
	e := testEngine(t, &fakeConn{cur: connector.SlotA})
	e.StateMount = e.StateDir // a real dir that is NOT its own mountpoint
	if err := os.MkdirAll(e.StateMount, 0o755); err != nil {
		t.Fatal(err)
	}

	err := e.Commit()
	if err == nil {
		t.Fatal("Commit proceeded with an unmounted state partition; want refusal")
	}
	if errors.Is(err, ErrNothingToCommit) {
		t.Fatalf("Commit reported nothing-to-commit (exit 2 = success) with the state "+
			"partition unmounted — the silent no-op we must prevent: %v", err)
	}
}

// A state partition path that does not exist at all is "not available", so the
// guard fails CLOSED (refuses) — the deliberate inverse of the ubootenv env
// guard, because here an undeterminable /data is exactly the state we must not
// treat as "nothing to commit".
func TestCommitRefusesWhenStatePartitionAbsent(t *testing.T) {
	e := testEngine(t, &fakeConn{cur: connector.SlotA})
	e.StateMount = filepath.Join(e.StateDir, "does-not-exist")

	err := e.Commit()
	if err == nil || errors.Is(err, ErrNothingToCommit) {
		t.Fatalf("Commit did not refuse when the state partition path is absent: %v", err)
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
