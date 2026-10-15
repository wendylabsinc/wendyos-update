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
	scans := 0
	list := c.listPartsFn
	c.listPartsFn = func(root string) ([]partInfo, error) { scans++; return list(root) }
	e := &engine.Engine{Conn: liveStatusConnector{c}, StateDir: t.TempDir()}
	before, err := e.Status(true)
	if err != nil {
		t.Fatal(err)
	}
	if scans != 5 {
		t.Fatalf("baseline used %d scans, want 5", scans)
	}
	scans = 0
	e.Conn = c
	after, err := e.Status(true)
	if err != nil {
		t.Fatal(err)
	}
	if scans != 1 {
		t.Fatalf("snapshot used %d scans, want 1", scans)
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
