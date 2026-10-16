package grubenv

import (
	"reflect"
	"testing"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
	"github.com/wendylabsinc/wendyos-update/internal/engine"
)

// Hide the optional snapshot interface to compare the old status path with
// the optimized path using the same connector and observations.
type liveStatusConnector struct{ connector.Connector }

func TestEngineStatusUsesOneScanAndPreservesMetadata(t *testing.T) {
	c := testController(t, newFakeEnv(map[string]string{
		envBootSlot: "1", envUpgradeAvailable: "1", envBootCount: "1",
	}), connector.SlotB, true)
	env := &countingEnv{envStore: c.env, reads: make(map[string]int)}
	c.env = env
	scans := 0
	list := c.listPartsFn
	c.listPartsFn = func(root string) ([]partInfo, error) { scans++; return list(root) }
	e := &engine.Engine{Conn: liveStatusConnector{c}, StateDir: t.TempDir()}
	before, err := e.Status(true)
	if err != nil {
		t.Fatal(err)
	}
	scans = 0
	clear(env.reads)
	e.Conn = c
	after, err := e.Status(true)
	if err != nil {
		t.Fatal(err)
	}
	if scans != 1 {
		t.Fatalf("snapshot used %d scans, want 1", scans)
	}
	for name, n := range env.reads {
		if n != 1 {
			t.Fatalf("snapshot read %s %d times, want once", name, n)
		}
	}
	if !reflect.DeepEqual(after, before) {
		t.Fatalf("status metadata changed\nbefore: %+v\nafter: %+v", before, after)
	}
	if e.Conn != c {
		t.Fatal("status replaced the engine's live connector")
	}
	if _, err := e.Status(true); err != nil {
		t.Fatal(err)
	}
	if scans != 2 {
		t.Fatalf("second status must scan again; total = %d", scans)
	}
}

// countingEnv counts reads per variable.
type countingEnv struct {
	envStore
	reads map[string]int
}

func (e *countingEnv) get(name string) (string, error) {
	e.reads[name]++
	return e.envStore.get(name)
}

func TestStatusSnapshotIsReadOnly(t *testing.T) {
	env := newFakeEnv(map[string]string{envBootSlot: "0"})
	c := testController(t, env, connector.SlotA, true)
	view := c.StatusSnapshot().(*Controller)
	if err := view.env.set(map[string]string{envBootSlot: "1"}); err == nil {
		t.Fatal("status snapshot accepted a write")
	}
	if env.vars[envBootSlot] != "0" || env.setCalls != 0 {
		t.Fatalf("snapshot wrote the env: %v, %d set calls", env.vars, env.setCalls)
	}
}
