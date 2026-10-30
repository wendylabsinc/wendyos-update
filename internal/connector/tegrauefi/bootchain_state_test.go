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

// nvbootctrlModel fakes nvbootctrl as it behaves on r39.2, where
// set-active-boot-slot writes only BootChainFwNext, and publishes the
// firmware's BootChainFwCurrent for the running slot.
func nvbootctrlModel(t *testing.T, c *Controller, current connector.Slot) string {
	t.Helper()
	logPath := filepath.Join(t.TempDir(), "calls")
	next := filepath.Join(c.EfivarsDir, "BootChainFwNext-"+VendorGUID)
	script := `#!/bin/sh
echo "$*" >> 'LOG'
NEXT='NEXT_PATH'
if [ "$1" = "-t" ]; then shift 2; fi
case "$1" in
get-current-slot) echo CUR ;;
set-active-boot-slot)
	{ printf '\007\000\000\000'; printf "\\00$2"; printf '\000\000\000'; } 2>/dev/null > "$NEXT" ;;
esac
exit 0
`
	script = strings.NewReplacer("LOG", logPath, "NEXT_PATH", next, "CUR", fmt.Sprint(int(current))).Replace(script)
	c.Nvbootctrl = filepath.Join(t.TempDir(), "nvbootctrl")
	if err := os.WriteFile(c.Nvbootctrl, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	bootChainTestVar(t, c, "BootChainFwCurrent", uint32(current))
	return logPath
}

// Rolling back to the running slot must leave no boot-chain request behind:
// one for the running slot changes nothing at boot, yet NVIDIA's capsule
// check refuses every later install until a reboot consumes it.
func TestRollbackToRunningSlotWithdrawsRequest(t *testing.T) {
	for _, soc := range []string{"nvidia,tegra264", "nvidia,tegra234"} {
		for _, tc := range []struct {
			name    string
			next    []byte
			status  uint32
			settled bool
		}{
			{name: "capsule install left no request"},
			{name: "rootfs-only install requested the target", next: []byte{7, 0, 0, 0, 1, 0, 0, 0}},
			{name: "redundant request for the running slot", next: []byte{7, 0, 0, 0, 0, 0, 0, 0}},
			{name: "malformed request", next: []byte{7, 0, 0, 0, 255, 0, 0, 0}},
			{name: "request after a successful switch", next: []byte{7, 0, 0, 0, 1, 0, 0, 0}, status: 0, settled: true},
			{name: "request after a no-op switch", next: []byte{7, 0, 0, 0, 1, 0, 0, 0}, status: 2, settled: true},
		} {
			t.Run(soc+"/"+tc.name, func(t *testing.T) {
				c := testController(t)
				writeCompatible(t, c, soc)
				calls := nvbootctrlModel(t, c, connector.SlotA)
				if tc.next != nil {
					if err := os.WriteFile(filepath.Join(c.EfivarsDir, "BootChainFwNext-"+VendorGUID), tc.next, 0o644); err != nil {
						t.Fatal(err)
					}
				}
				if tc.settled {
					bootChainTestVar(t, c, "BootChainFwStatus", tc.status)
				}
				if err := c.SwapSlot(connector.SlotA, false); err != nil {
					t.Fatal(err)
				}
				raw, err := os.ReadFile(calls)
				if err != nil || !strings.Contains(string(raw), "get-current-slot") {
					t.Fatalf("rollback never asked nvbootctrl for the running slot: %q, %v", raw, err)
				}
				if strings.Contains(string(raw), "set-active-boot-slot") {
					t.Fatalf("rollback to the running slot issued a boot-chain request: %s", raw)
				}
				if _, err := os.Stat(filepath.Join(c.EfivarsDir, "BootChainFwNext-"+VendorGUID)); !os.IsNotExist(err) {
					t.Fatalf("BootChainFwNext survived the rollback: %v", err)
				}
				// A settled status is the verifier's to clear, not the rollback's.
				if err := c.checkCapsuleBootChainIdle(); (err != nil) != tc.settled {
					t.Fatalf("boot chain idle = %v after rollback, want blocked=%t", err, tc.settled)
				}
				if _, err := os.Stat(c.bootAttemptedPath()); !os.IsNotExist(err) {
					t.Fatalf("rollback to the running slot recorded a boot attempt: %v", err)
				}
			})
		}
	}
}

// A request that cannot be withdrawn must not strand the rollback: re-pointing
// still makes the running slot the next boot.
func TestRollbackRepointsWhenRequestCannotBeWithdrawn(t *testing.T) {
	c := testController(t)
	writeCompatible(t, c, "nvidia,tegra264")
	calls := nvbootctrlModel(t, c, connector.SlotA)
	stuck := filepath.Join(c.EfivarsDir, "BootChainFwNext-"+VendorGUID)
	if err := os.MkdirAll(filepath.Join(stuck, "pin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := c.SwapSlot(connector.SlotA, false); err != nil {
		t.Fatalf("rollback refused when the request could not be withdrawn: %v", err)
	}
	raw, _ := os.ReadFile(calls)
	if !strings.Contains(string(raw), "set-active-boot-slot 0") {
		t.Fatalf("rollback did not re-point the slot: %s", raw)
	}
}

// Leaving the running slot needs a real boot-chain request, and so do a switch
// the firmware is still judging by its request, a capsule that is still armed
// and a firmware chain that is not the running slot; unreadable evidence never
// strands the rollback either.
func TestRollbackRepointsUnlessKeepingRunningSlotIsSafe(t *testing.T) {
	for _, soc := range []string{"nvidia,tegra264", "nvidia,tegra234"} {
		for _, tc := range []struct {
			name         string
			current      connector.Slot
			status, osi  []byte
			chain        []byte
			unknownChain bool
		}{
			{name: "running B after reboot", current: connector.SlotB},
			{name: "firmware switch in progress", status: []byte{7, 0, 0, 0, 1, 0, 0, 0}},
			{name: "unreadable switch status", status: []byte{7}},
			{name: "capsule still armed", osi: []byte{7, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0}},
			{name: "firmware booted the other chain", chain: []byte{6, 0, 0, 0, 1, 0, 0, 0}},
			{name: "running rootfs B although chain A is the target", current: connector.SlotB, chain: []byte{6, 0, 0, 0, 0, 0, 0, 0}},
			{name: "firmware chain unknown", unknownChain: true},
		} {
			t.Run(soc+"/"+tc.name, func(t *testing.T) {
				c := testController(t)
				writeCompatible(t, c, soc)
				calls := nvbootctrlModel(t, c, tc.current)
				for name, raw := range map[string][]byte{
					"BootChainFwStatus-" + VendorGUID:  tc.status,
					"OsIndications-" + EfiGlobalGUID:   tc.osi,
					"BootChainFwCurrent-" + VendorGUID: tc.chain,
				} {
					if raw != nil {
						if err := os.WriteFile(filepath.Join(c.EfivarsDir, name), raw, 0o644); err != nil {
							t.Fatal(err)
						}
					}
				}
				if tc.unknownChain {
					if err := os.Remove(filepath.Join(c.EfivarsDir, "BootChainFwCurrent-"+VendorGUID)); err != nil {
						t.Fatal(err)
					}
				}
				if err := c.SwapSlot(connector.SlotA, false); err != nil {
					t.Fatalf("rollback refused: %v", err)
				}
				want := "-t rootfs set-active-boot-slot 0"
				if soc == "nvidia,tegra234" {
					want = "\nset-active-boot-slot 0"
				}
				raw, _ := os.ReadFile(calls)
				if !strings.Contains("\n"+string(raw), want) {
					t.Fatalf("rollback did not re-point the slot with %q: %s", want, raw)
				}
			})
		}
	}
}

// Where capsules are not staged a leftover request blocks nothing, so an
// unvalidated SoC keeps the plain re-point even from a clean state.
func TestRollbackRepointsOnUnvalidatedSoC(t *testing.T) {
	c := testController(t)
	writeCompatible(t, c, "nvidia,tegra999")
	calls := nvbootctrlModel(t, c, connector.SlotA)
	if err := c.SwapSlot(connector.SlotA, false); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(calls)
	if !strings.Contains(string(raw), "-t rootfs set-active-boot-slot 0") {
		t.Fatalf("rollback on an unvalidated SoC did not re-point: %s", raw)
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
