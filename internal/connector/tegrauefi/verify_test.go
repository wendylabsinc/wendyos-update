package tegrauefi

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

func TestBootIsCompromised(t *testing.T) {
	const normal = "\x07\x00\x00\x00\x00\x00\x00\x00"
	const unbootable = "\x07\x00\x00\x00\xff\x00\x00\x00"

	// runningA / runningB stub `nvbootctrl get-current-slot`.
	runningA := func() string { return fakeNvbootctrl(t, "0\n") }
	runningB := func() string { return fakeNvbootctrl(t, "1\n") }

	t.Run("no status var for the booted slot", func(t *testing.T) {
		c := testController(t)
		c.Nvbootctrl = runningA()
		if got, err := c.BootIsCompromised(); err != nil || got {
			t.Fatalf("no vars: got=%v err=%v", got, err)
		}
	})

	t.Run("booted slot normal", func(t *testing.T) {
		c := testController(t)
		c.Nvbootctrl = runningA()
		writeSlotVar(t, c, connector.SlotA, []byte(normal))
		writeSlotVar(t, c, connector.SlotB, []byte(normal))
		if got, _ := c.BootIsCompromised(); got {
			t.Fatal("booted slot normal: must not be compromised")
		}
	})

	// WDY-1742 regression: a stale 0xFF left on the INACTIVE slot must not
	// flag a healthy boot of the active slot (the old both-slots scan did).
	t.Run("stale unbootable on inactive slot is ignored", func(t *testing.T) {
		c := testController(t)
		c.Nvbootctrl = runningA() // booted A
		writeSlotVar(t, c, connector.SlotA, []byte(normal))
		writeSlotVar(t, c, connector.SlotB, []byte(unbootable))
		if got, _ := c.BootIsCompromised(); got {
			t.Fatal("stale inactive 0xFF: must NOT be compromised")
		}
	})

	t.Run("booted slot unbootable", func(t *testing.T) {
		c := testController(t)
		c.Nvbootctrl = runningB() // booted B
		writeSlotVar(t, c, connector.SlotB, []byte(unbootable))
		if got, _ := c.BootIsCompromised(); !got {
			t.Fatal("booted slot 0xFF: must be compromised")
		}
	})

	// WDY-1742: an unvalidated size is inconclusive, not compromised — the
	// engine's slot check + ESRT cascade stay authoritative.
	t.Run("unexpected size is inconclusive", func(t *testing.T) {
		c := testController(t)
		c.Nvbootctrl = runningB()                                  // booted B
		writeSlotVar(t, c, connector.SlotB, []byte{0x07, 0, 0, 0}) // 4 bytes, no status word
		if got, _ := c.BootIsCompromised(); got {
			t.Fatal("unexpected size: must be inconclusive (not compromised)")
		}
	})
}

// verifySetup prepares RootDir with the marker, optional saved version,
// and optional ESRT status.
func verifySetup(t *testing.T, c *Controller, savedVersion, esrtStatus string) {
	t.Helper()
	marker := c.RootDir + MarkerPath
	os.MkdirAll(filepath.Dir(marker), 0o755)
	os.WriteFile(marker, nil, 0o644)

	if savedVersion != "" {
		p := c.blVersionBeforePath()
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte(savedVersion+"\n"), 0o644)
	}
	if esrtStatus != "" {
		p := c.RootDir + ESRTStatusPath
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte(esrtStatus+"\n"), 0o644)
	}
}

func dumpSlotsInfoFake(t *testing.T, version string) string {
	return fakeNvbootctrl(t, "Current version: "+version+"\nCapsule update status: 1\n")
}

func TestVerifyPlatformUpdateNoMarker(t *testing.T) {
	c := testController(t)
	if err := c.VerifyPlatformUpdate(false); err != nil {
		t.Fatal(err)
	}
}

func TestVerifyPlatformUpdateVersionChanged(t *testing.T) {
	c := testController(t)
	c.Nvbootctrl = dumpSlotsInfoFake(t, "38.5.0")
	verifySetup(t, c, "38.4.0", "")

	if err := c.VerifyPlatformUpdate(true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(c.blVersionBeforePath()); !os.IsNotExist(err) {
		t.Fatal("bl-version-before not cleaned up after success")
	}
}

func TestVerifyPlatformUpdateSameVersionESRTSuccess(t *testing.T) {
	c := testController(t)
	c.Nvbootctrl = dumpSlotsInfoFake(t, "38.4.0")
	verifySetup(t, c, "38.4.0", "0")

	if err := c.VerifyPlatformUpdate(true); err != nil {
		t.Fatal(err)
	}
}

func TestVerifyPlatformUpdateESRTBootChainCanceled(t *testing.T) {
	c := testController(t)
	c.Nvbootctrl = dumpSlotsInfoFake(t, "38.4.0")
	verifySetup(t, c, "38.4.0", "6163")

	err := c.VerifyPlatformUpdate(true)
	if err == nil || !strings.Contains(err.Error(), "6163") {
		t.Fatalf("want 6163 boot-chain cancellation, got %v", err)
	}
}

func TestVerifyPlatformUpdateESRTStandardError(t *testing.T) {
	c := testController(t)
	c.Nvbootctrl = dumpSlotsInfoFake(t, "38.4.0")
	verifySetup(t, c, "38.4.0", "4")

	if err := c.VerifyPlatformUpdate(true); err == nil {
		t.Fatal("ESRT status 4 must fail verification")
	}
}

func TestVerifyPlatformUpdateFallbackBootSuccess(t *testing.T) {
	c := testController(t)
	c.Nvbootctrl = dumpSlotsInfoFake(t, "38.4.0")
	verifySetup(t, c, "", "") // no saved version, no ESRT

	if err := c.VerifyPlatformUpdate(true); err != nil {
		t.Fatalf("fallback must assume success: %v", err)
	}
}

var osIndicationsArmed = []byte{7, 0, 0, 0, osIndicationsProcessCapsule, 0, 0, 0, 0, 0, 0, 0}

// The capsule bit is cleared before the ESP is looked up, so an unresolvable
// ESP or a leftover version file can neither leave the update armed nor fail
// the rollback.
func TestAbortDisarmsCapsuleWhenESPCannotBeResolved(t *testing.T) {
	for _, tc := range []struct {
		name  string
		armed bool
		edit  func(c *Controller)
	}{
		{"armed, lsblk fails", true, func(c *Controller) {
			c.listPartsFn = func() ([]partitionInfo, error) { return nil, errors.New("lsblk failed") }
		}},
		{"armed, ESP ambiguous", true, func(c *Controller) {
			c.listPartsFn = func() ([]partitionInfo, error) {
				p := dualDiskParts()
				q := p[7]
				q.Path, q.DeviceID, q.PartLabel = "/dev/nvme0n1p14", "259:14", "UEFI-ESP"
				return append(p, q), nil
			}
		}},
		{"stale version file only, root unknown", false, func(c *Controller) {
			c.rootIDFn = func() (string, error) { return "8:99", nil }
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := storageController(t)
			tc.edit(c)
			osi := filepath.Join(c.EfivarsDir, "OsIndications-"+EfiGlobalGUID)
			if tc.armed {
				if err := os.WriteFile(osi, osIndicationsArmed, 0o644); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.MkdirAll(filepath.Dir(c.blVersionBeforePath()), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(c.blVersionBeforePath(), []byte("39.2.0\n"), 0o644); err != nil {
				t.Fatal(err)
			}

			if err := c.AbortPlatformUpdate(); err != nil {
				t.Fatalf("abort failed the rollback: %v", err)
			}
			if raw, err := os.ReadFile(osi); err == nil && len(raw) >= 5 && raw[4]&osIndicationsProcessCapsule != 0 {
				t.Fatalf("capsule still armed: % x", raw)
			}
			if _, err := os.Stat(c.blVersionBeforePath()); !os.IsNotExist(err) {
				t.Fatalf("pre-update version survived the abort: %v", err)
			}
		})
	}
}

// A failure to disarm is the one abort error that must stop the rollback.
func TestAbortFailsWhenCapsuleCannotBeDisarmed(t *testing.T) {
	c := storageController(t)
	osi := filepath.Join(c.EfivarsDir, "OsIndications-"+EfiGlobalGUID)
	if err := os.Mkdir(osi, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := c.AbortPlatformUpdate(); err == nil {
		t.Fatal("unreadable OsIndications reported as disarmed")
	}
}
