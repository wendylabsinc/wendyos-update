package tegrauefi

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// osIndicationsSupportedVar is the efivarfs filename for the firmware's
// capsule-on-disk capability signal.
const osIndicationsSupportedVar = "OsIndicationsSupported-" + EfiGlobalGUID

// writeOsIndicationsSupported fakes the OsIndicationsSupported UEFI variable
// under the controller's EfivarsDir. capsuleBit controls FILE_CAPSULE_DELIVERY
// (bit 2). Layout matches the device: 4-byte attrs (0x06 = BS+RT) + UINT64, so
// byte[4] carries bits 0..7. When set, byte[4] = 0x45 mirrors the real Orin Nano
// r39.2 value (bits 0, 2, 6), which also exercises masking bit 2 out of others.
func writeOsIndicationsSupported(t *testing.T, c *Controller, capsuleBit bool) {
	t.Helper()
	payload := []byte{0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}
	if capsuleBit {
		payload[4] = 0x45
	}
	if err := os.WriteFile(filepath.Join(c.EfivarsDir, osIndicationsSupportedVar), payload, 0o644); err != nil {
		t.Fatal(err)
	}
}

// capsuleUpdateEffective gates the bootloader-capsule path on the firmware's own
// capability signal: OsIndicationsSupported advertising FILE_CAPSULE_DELIVERY
// (bit 2). Verified on Thor (t264/r38) and Orin (t234/r39.2 — reads 0x45). When
// unsupported/absent, the connector falls back to the nvbootctrl slot switch.
func TestCapsuleUpdateEffective(t *testing.T) {
	for _, tc := range []struct {
		name string
		raw  []byte // nil = variable absent
		want bool
	}{
		{"capsule bit set (0x45, as on Orin r39.2)", []byte{0x06, 0, 0, 0, 0x45, 0, 0, 0, 0, 0, 0, 0}, true},
		{"capsule bit only (0x04)", []byte{0x06, 0, 0, 0, 0x04, 0, 0, 0, 0, 0, 0, 0}, true},
		{"other bits but not capsule (0x41)", []byte{0x06, 0, 0, 0, 0x41, 0, 0, 0, 0, 0, 0, 0}, false},
		{"no bits set", []byte{0x06, 0, 0, 0, 0x00, 0, 0, 0, 0, 0, 0, 0}, false},
		{"short/malformed (<5 bytes)", []byte{0x06, 0, 0, 0}, false},
		{"variable absent", nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := testController(t)
			if tc.raw != nil {
				if err := os.WriteFile(filepath.Join(c.EfivarsDir, osIndicationsSupportedVar), tc.raw, 0o644); err != nil {
					t.Fatal(err)
				}
			}
			if got := c.capsuleUpdateEffective(); got != tc.want {
				t.Fatalf("capsuleUpdateEffective() = %v, want %v", got, tc.want)
			}
		})
	}
}

// settleBootChain must clear the pending-FW-chain-switch UEFI variables that
// make the firmware cancel a capsule with 6163 (LAS_ERROR_BOOT_CHAIN_UPDATE_CANCELED):
// both BootChainFwNext and BootChainFwStatus. It must also be a no-op when they
// are absent. On-device (Orin Nano r39.2) efivarfs delete clears both.
func TestSettleBootChain(t *testing.T) {
	c := testController(t)
	next := filepath.Join(c.EfivarsDir, "BootChainFwNext-"+VendorGUID)
	status := filepath.Join(c.EfivarsDir, "BootChainFwStatus-"+VendorGUID)

	// The stale, capsule-blocking state: both variables present.
	for _, p := range []string{next, status} {
		if err := os.WriteFile(p, []byte{0x07, 0, 0, 0, 0x01, 0, 0, 0}, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	if err := c.settleBootChain(); err != nil {
		t.Fatalf("settleBootChain with vars present: %v", err)
	}
	for _, p := range []string{next, status} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("expected %s deleted, stat err = %v", filepath.Base(p), err)
		}
	}

	// Idempotent: a clean chain settles without error.
	if err := c.settleBootChain(); err != nil {
		t.Fatalf("settleBootChain when already clean: %v", err)
	}
}

// installSwapSetup wires a controller so SwapSlot(_, true) can reach the
// marker-inspection branch without real block devices: PartitionFor resolves
// via a by-partlabel symlink under RootDir, and mountFn returns a fake rootfs
// mount whose marker presence the test controls.
func installSwapSetup(t *testing.T, c *Controller, target connector.Slot, hasMarker bool) {
	t.Helper()

	// PartitionFor(target) resolves the APP/APP_b by-partlabel symlink.
	label := partlabelFor(target)
	linkDir := filepath.Join(c.RootDir, "dev", "disk", "by-partlabel")
	if err := os.MkdirAll(linkDir, 0o755); err != nil {
		t.Fatal(err)
	}
	devFile := filepath.Join(c.RootDir, "fake-"+label)
	if err := os.WriteFile(devFile, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(devFile, filepath.Join(linkDir, label)); err != nil {
		t.Fatal(err)
	}

	// mountFn returns a fake rootfs mount; the marker decides which branch
	// SwapSlot takes.
	mountDir := t.TempDir()
	if hasMarker {
		markerPath := filepath.Join(mountDir, strings.TrimPrefix(MarkerPath, "/"))
		if err := os.MkdirAll(filepath.Dir(markerPath), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(markerPath, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	c.mountFn = func(string) (string, func(), error) { return mountDir, func() {}, nil }
}

// On a platform whose firmware does NOT advertise capsule-on-disk, an install
// swap for an image that carries the bootloader marker must still switch the
// active slot via nvbootctrl — otherwise the update silently no-ops (the slot
// never moves, the device reboots into the same OS). It must NOT stage a capsule
// or arm OsIndications on this platform.
func TestSwapSlotSwitchesSlotWhenCapsuleIneffective(t *testing.T) {
	c := testController(t)
	logPath := filepath.Join(t.TempDir(), "calls.log")
	c.Nvbootctrl = recordingNvbootctrl(t, logPath, "0\n") // running slot A
	writeOsIndicationsSupported(t, c, false /* capsule not advertised */)
	installSwapSetup(t, c, connector.SlotB, true /* marker present */)

	if err := c.SwapSlot(connector.SlotB, true); err != nil {
		t.Fatalf("SwapSlot returned error on ineffective-capsule platform: %v", err)
	}

	calls, _ := os.ReadFile(logPath)
	if !strings.Contains(string(calls), "-t rootfs set-active-boot-slot 1") {
		t.Fatalf("expected nvbootctrl slot switch to B; calls were:\n%s", calls)
	}
	// OsIndications must not be armed (no capsule to process).
	osi := filepath.Join(c.EfivarsDir, "OsIndications-"+EfiGlobalGUID)
	if raw, err := os.ReadFile(osi); err == nil && len(raw) >= 5 && raw[4]&osIndicationsProcessCapsule != 0 {
		t.Fatalf("OsIndications capsule bit armed on ineffective platform: % x", raw)
	}
}

// On a platform whose firmware advertises capsule-on-disk, an install swap for
// a bootloader-carrying image must take the capsule path — it must NOT fall
// back to the nvbootctrl slot switch (doing both is the documented BC_NEXT
// conflict). Staging needs a real ESP, so here we only assert the routing:
// nvbootctrl is never used to switch the slot on this path.
func TestSwapSlotDoesNotSwitchSlotWhenCapsuleEffective(t *testing.T) {
	c := testController(t)
	logPath := filepath.Join(t.TempDir(), "calls.log")
	c.Nvbootctrl = recordingNvbootctrl(t, logPath, "0\n")
	writeOsIndicationsSupported(t, c, true /* capsule advertised */)
	installSwapSetup(t, c, connector.SlotB, true /* marker present */)

	// Staging cannot complete without a real ESP; that's fine — we only care
	// that the capsule path was chosen, not the nvbootctrl slot switch.
	_ = c.SwapSlot(connector.SlotB, true)

	calls, _ := os.ReadFile(logPath)
	if strings.Contains(string(calls), "set-active-boot-slot") {
		t.Fatalf("capsule-effective platform must not switch the slot via nvbootctrl; calls were:\n%s", calls)
	}
}
