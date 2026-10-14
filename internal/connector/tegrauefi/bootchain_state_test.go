package tegrauefi

import (
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

func bootChainTestController(t *testing.T, current, dump string) (*Controller, string) {
	t.Helper()
	c := testController(t)
	writeCompatible(t, c, "nvidia,tegra234")
	logPath := filepath.Join(t.TempDir(), "calls")
	c.Nvbootctrl = filepath.Join(t.TempDir(), "nvbootctrl")
	script := "#!/bin/sh\n" +
		"echo \"$*\" >> '" + logPath + "'\n" +
		"case \"$*\" in\n" +
		"get-current-slot) printf '%s' '" + current + "';;\n" +
		"dump-slots-info) printf '%s' '" + dump + "';;\n" +
		"esac\n"
	if err := os.WriteFile(c.Nvbootctrl, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return c, logPath
}

func bootChainTestVar(t *testing.T, c *Controller, name string, value uint32) string {
	t.Helper()
	raw := make([]byte, 8)
	binary.LittleEndian.PutUint32(raw, 7)
	binary.LittleEndian.PutUint32(raw[4:], value)
	path := filepath.Join(c.EfivarsDir, name+"-"+VendorGUID)
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// A firmware fallback already completed the requested rollback. Re-arming A
// here would leave BootChainFwNext=0 and make the next capsule fail with 6163.
func TestRollbackAlreadyActiveAvoidsNewBootChainRequest(t *testing.T) {
	c, calls := bootChainTestController(t, "0\n", "Current bootloader slot: A\nActive bootloader slot: A\n")
	if err := c.SwapSlot(connector.SlotA, false); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(calls)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "set-active-boot-slot") {
		t.Fatalf("settled rollback created another boot-chain request: %s", raw)
	}
	if _, err := os.Stat(c.bootAttemptedPath()); !os.IsNotExist(err) {
		t.Fatalf("settled rollback recorded a boot attempt: %v", err)
	}
}

// Userspace can still be on A while B is armed for the next boot. Rollback
// must retain its switch operation in that case, and must not delete EFI
// variables directly while deciding whether the operation is redundant.
func TestRollbackKeepsPendingSwitchCancellation(t *testing.T) {
	for _, tc := range []struct {
		name, current, dump string
		pending             bool
	}{
		{"pending B before reboot", "0\n", "Current bootloader slot: A\nActive bootloader slot: B\n", true},
		{"active B before reboot", "0\n", "Current bootloader slot: A\nActive bootloader slot: B\n", false},
		{"running B after reboot", "1\n", "Current bootloader slot: B\nActive bootloader slot: B\n", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, calls := bootChainTestController(t, tc.current, tc.dump)
			var nextPath string
			if tc.pending {
				nextPath = bootChainTestVar(t, c, "BootChainFwNext", 1)
			}
			if err := c.SwapSlot(connector.SlotA, false); err != nil {
				t.Fatal(err)
			}
			raw, _ := os.ReadFile(calls)
			if !strings.Contains(string(raw), "set-active-boot-slot 0") {
				t.Fatalf("rollback failed to cancel/switch the active target: %s", raw)
			}
			if nextPath != "" {
				raw, err := os.ReadFile(nextPath)
				if err != nil || binary.LittleEndian.Uint32(raw[4:]) != 1 {
					t.Fatalf("inspection altered pending request: %x, %v", raw, err)
				}
			}
		})
	}
}

func TestRollbackCannotInferSettledStateFromBadEvidence(t *testing.T) {
	for _, tc := range []struct {
		name, dump string
		badNext    bool
	}{
		{"missing active slot", "Current bootloader slot: A\n", false},
		{"unknown active slot", "Current bootloader slot: A\nActive bootloader slot: Z\n", false},
		{"conflicting current slot", "Current bootloader slot: B\nActive bootloader slot: A\n", false},
		{"duplicate active slot", "Current bootloader slot: A\nActive bootloader slot: A\nActive bootloader slot: B\n", false},
		{"invalid pending slot", "Current bootloader slot: A\nActive bootloader slot: A\n", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, calls := bootChainTestController(t, "0\n", tc.dump)
			if tc.badNext {
				bootChainTestVar(t, c, "BootChainFwNext", 255)
			}
			if err := c.SwapSlot(connector.SlotA, false); err == nil {
				t.Fatal("rollback inferred a settled state from invalid evidence")
			}
			raw, _ := os.ReadFile(calls)
			if strings.Contains(string(raw), "set-active-boot-slot") {
				t.Fatalf("rollback mutated state after failed inspection: %s", raw)
			}
		})
	}
}

func TestCapsuleBootChainIdleRejectsExistingStateWithoutClearingIt(t *testing.T) {
	for _, name := range []string{"BootChainFwNext", "BootChainFwStatus"} {
		for _, value := range []uint32{0, 1, 3} {
			t.Run(fmt.Sprintf("%s=%d", name, value), func(t *testing.T) {
				c := testController(t)
				path := bootChainTestVar(t, c, name, value)
				before, _ := os.ReadFile(path)
				if err := c.checkCapsuleBootChainIdle(); err == nil {
					t.Fatalf("existing %s=%d should block capsule staging: %v", name, value, err)
				}
				after, err := os.ReadFile(path)
				if err != nil || string(before) != string(after) {
					t.Fatalf("capsule preflight altered %s: %x, %v", name, after, err)
				}
			})
		}
	}
}

func TestCapsuleBootChainIdleRejectsBootOverrideAndUnreadableState(t *testing.T) {
	for _, scenario := range []string{"BootNext", "malformed variable", "unreadable variable", "missing EFI directory"} {
		t.Run(scenario, func(t *testing.T) {
			c := testController(t)
			switch scenario {
			case "BootNext":
				if err := os.WriteFile(filepath.Join(c.EfivarsDir, "BootNext-"+EfiGlobalGUID), []byte{7, 0, 0, 0, 1, 0}, 0o644); err != nil {
					t.Fatal(err)
				}
			case "malformed variable":
				if err := os.WriteFile(filepath.Join(c.EfivarsDir, "BootChainFwNext-"+VendorGUID), []byte{0}, 0o644); err != nil {
					t.Fatal(err)
				}
			case "unreadable variable":
				if err := os.Mkdir(filepath.Join(c.EfivarsDir, "BootChainFwNext-"+VendorGUID), 0o755); err != nil {
					t.Fatal(err)
				}
			case "missing EFI directory":
				c.EfivarsDir = filepath.Join(t.TempDir(), "absent")
			}
			if err := c.checkCapsuleBootChainIdle(); err == nil {
				t.Fatal("unsafe capsule preflight passed")
			}
		})
	}
	if err := testController(t).checkCapsuleBootChainIdle(); err != nil {
		t.Fatalf("settled boot should allow staging: %v", err)
	}
}
