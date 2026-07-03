package tegrauefi

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// writeCompatible fakes /proc/device-tree/compatible under the controller's
// RootDir with the given NUL-separated SoC compatible strings (the real file
// is a NUL-separated, NUL-terminated list, e.g. "nvidia,p3701-0000\0nvidia,tegra234\0").
func writeCompatible(t *testing.T, c *Controller, entries ...string) {
	t.Helper()
	dir := filepath.Join(c.RootDir, "proc", "device-tree")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := strings.Join(entries, "\x00") + "\x00"
	if err := os.WriteFile(filepath.Join(dir, "compatible"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// capsuleUpdateEffective gates the bootloader-capsule path: UEFI
// capsule-on-disk is only honored on platforms where it has been validated
// (Thor / tegra264). On Orin (tegra234) and unknown SoCs the firmware silently
// ignores a staged capsule, so the connector must fall back to the reliable
// nvbootctrl slot switch instead of betting the whole update on a capsule that
// never gets processed.
func TestCapsuleUpdateEffective(t *testing.T) {
	for _, tc := range []struct {
		name     string
		entries  []string
		writeVar bool
		want     bool
	}{
		{"thor tegra264 is effective", []string{"nvidia,p3834-0008", "nvidia,tegra264"}, true, true},
		{"orin tegra234 is not effective", []string{"nvidia,p3701-0000", "nvidia,tegra234"}, true, false},
		{"orin nano tegra234 is not effective", []string{"nvidia,p3767-0000", "nvidia,tegra234"}, true, false},
		{"missing compatible defaults to not effective", nil, false, false},
		{"unknown soc defaults to not effective", []string{"nvidia,someboard", "nvidia,tegra999"}, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := testController(t)
			if tc.writeVar {
				writeCompatible(t, c, tc.entries...)
			}
			if got := c.capsuleUpdateEffective(); got != tc.want {
				t.Fatalf("capsuleUpdateEffective() = %v, want %v", got, tc.want)
			}
		})
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

// On a platform where capsule-on-disk is NOT effective (Orin), an install swap
// for an image that carries the bootloader marker must still switch the active
// slot via nvbootctrl — otherwise the update silently no-ops (the slot never
// moves, the device reboots into the same OS). It must NOT stage a capsule or
// arm OsIndications on this platform.
func TestSwapSlotSwitchesSlotWhenCapsuleIneffective(t *testing.T) {
	c := testController(t)
	logPath := filepath.Join(t.TempDir(), "calls.log")
	c.Nvbootctrl = recordingNvbootctrl(t, logPath, "0\n") // running slot A
	writeCompatible(t, c, "nvidia,p3701-0000", "nvidia,tegra234")
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

// On a platform where capsule-on-disk IS effective (Thor), an install swap for
// a bootloader-carrying image must take the capsule path — it must NOT fall
// back to the nvbootctrl slot switch (doing both is the documented BC_NEXT
// conflict). Staging needs a real ESP, so here we only assert the routing:
// nvbootctrl is never used to switch the slot on this path.
func TestSwapSlotDoesNotSwitchSlotWhenCapsuleEffective(t *testing.T) {
	c := testController(t)
	logPath := filepath.Join(t.TempDir(), "calls.log")
	c.Nvbootctrl = recordingNvbootctrl(t, logPath, "0\n")
	writeCompatible(t, c, "nvidia,p3834-0008", "nvidia,tegra264")
	installSwapSetup(t, c, connector.SlotB, true /* marker present */)

	// Staging cannot complete without a real ESP; that's fine — we only care
	// that the capsule path was chosen, not the nvbootctrl slot switch.
	_ = c.SwapSlot(connector.SlotB, true)

	calls, _ := os.ReadFile(logPath)
	if strings.Contains(string(calls), "set-active-boot-slot") {
		t.Fatalf("capsule-effective platform must not switch the slot via nvbootctrl; calls were:\n%s", calls)
	}
}
