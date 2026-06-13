package engine

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/wendylabsinc/wendy-os-update/internal/connector"
)

func TestCommitHealthGatePass(t *testing.T) {
	f := &fakeConn{cur: connector.SlotB} // running the target slot
	e := testEngine(t, f)
	hd := t.TempDir()
	e.HealthDir = hd
	writeHook(t, hd, "10-ok", "exit 0")
	e.SaveState(swappedState())

	if err := e.Commit(); err != nil {
		t.Fatalf("commit with passing health hook: %v", err)
	}
	if f.markGood != 1 {
		t.Fatal("MarkGood not called after passing health gate")
	}
	if st, _ := e.LoadState(); st != nil {
		t.Fatal("state not cleared after successful commit")
	}
}

func TestCommitHealthGateFail(t *testing.T) {
	f := &fakeConn{cur: connector.SlotB}
	e := testEngine(t, f)
	hd := t.TempDir()
	e.HealthDir = hd
	writeHook(t, hd, "10-bad", "exit 1")
	e.SaveState(swappedState())

	err := e.Commit()
	var hc *HookError
	if !errors.As(err, &hc) {
		t.Fatalf("want HookError, got %v", err)
	}
	// deployment marked failed (a reboot rolls back), MarkGood NOT called,
	// state retained.
	st, _ := e.LoadState()
	if st == nil || st.Phase != PhaseFailed {
		t.Fatalf("state after health failure: %+v", st)
	}
	if f.markGood != 0 {
		t.Fatal("MarkGood must not run when the health gate fails")
	}
	if _, err := os.Stat(filepath.Join(e.StateDir, "installed.json")); !os.IsNotExist(err) {
		t.Fatal("must not record install history on health failure")
	}
}
