package grubenv

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// grubenvValue must parse one variable out of `grub-editenv list` output and
// return "" for a missing one.
func TestGrubenvValue(t *testing.T) {
	list := "wendyos_boot_slot=1\nwendyos_upgrade_available=0\nbootcount=1\n"
	for name, want := range map[string]string{
		"wendyos_boot_slot":         "1",
		"wendyos_upgrade_available": "0",
		"bootcount":                 "1",
		"missing":                   "",
	} {
		if got := grubenvValue(list, name); got != want {
			t.Errorf("grubenvValue(%q) = %q, want %q", name, got, want)
		}
	}
}

// grubSetArgs must emit "key=value" positional args (grub-editenv's required
// form) after the path and the "set" verb.
func TestGrubSetArgs(t *testing.T) {
	args := grubSetArgs("/boot/EFI/BOOT/grubenv", map[string]string{
		"wendyos_boot_slot": "0",
		"bootcount":         "0",
	})
	if len(args) < 2 || args[0] != "/boot/EFI/BOOT/grubenv" || args[1] != "set" {
		t.Fatalf("grubSetArgs prefix wrong: %v", args)
	}
	joined := strings.Join(args, " ")
	for _, want := range []string{"wendyos_boot_slot=0", "bootcount=0"} {
		if !strings.Contains(joined, want) {
			t.Errorf("grubSetArgs missing %q in %v", want, args)
		}
	}
	for _, a := range args[2:] {
		if !strings.Contains(a, "=") {
			t.Errorf("grubSetArgs produced a pair without '=': %q", a)
		}
	}
}

// fakeEnv is an in-memory GRUB environment for tests (the envStore seam).
type fakeEnv struct {
	vars     map[string]string
	setCalls int
}

func newFakeEnv(initial map[string]string) *fakeEnv {
	m := map[string]string{}
	for k, v := range initial {
		m[k] = v
	}
	return &fakeEnv{vars: m}
}

func (f *fakeEnv) get(name string) (string, error) { return f.vars[name], nil }

func (f *fakeEnv) set(vars map[string]string) error {
	f.setCalls++
	for k, v := range vars {
		f.vars[k] = v
	}
	return nil
}

// testController builds a Controller wired to a fake env and a RootDir tempdir,
// with running-root forced to the given slot's device. Pass running = -1 to
// leave rootDeviceFn returning an unmatched device. makeSlots also creates the
// by-partlabel symlinks so the PartitionFor fallback resolves.
func testController(t *testing.T, env *fakeEnv, running connector.Slot, makeSlots bool) *Controller {
	t.Helper()
	c := New()
	c.env = env
	c.RootDir = t.TempDir()

	devA := c.RootDir + "/dev/rootfsA"
	devB := c.RootDir + "/dev/rootfsB"
	if makeSlots {
		if err := os.MkdirAll(filepath.Dir(devA), 0o755); err != nil {
			t.Fatal(err)
		}
		for _, d := range []string{devA, devB} {
			if err := os.WriteFile(d, nil, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		linkDir := c.RootDir + "/dev/disk/by-partlabel"
		if err := os.MkdirAll(linkDir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(devA, filepath.Join(linkDir, partlabelA)); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(devB, filepath.Join(linkDir, partlabelB)); err != nil {
			t.Fatal(err)
		}
	}

	c.rootDeviceFn = func() (string, error) {
		switch running {
		case connector.SlotA:
			return devA, nil
		case connector.SlotB:
			return devB, nil
		default:
			return c.RootDir + "/dev/unknown", nil
		}
	}

	// Single-disk fake: both slots live on one disk ("nvme0n1"). Exercises the
	// boot-disk-scoped resolution path; empty when makeSlots is false.
	c.listPartsFn = func() ([]partInfo, error) {
		if !makeSlots {
			return nil, nil
		}
		return []partInfo{
			{path: devA, partlabel: partlabelA, pkname: "nvme0n1"},
			{path: devB, partlabel: partlabelB, pkname: "nvme0n1"},
		}, nil
	}
	return c
}

func TestName(t *testing.T) {
	if New().Name() != "grubenv" {
		t.Fatalf("Name = %q, want grubenv", New().Name())
	}
}

func TestSlotEnvValue(t *testing.T) {
	if slotEnvValue(connector.SlotA) != "0" || slotEnvValue(connector.SlotB) != "1" {
		t.Fatalf("slotEnvValue mapping wrong: A=%q B=%q", slotEnvValue(connector.SlotA), slotEnvValue(connector.SlotB))
	}
}

func TestPartitionFor(t *testing.T) {
	c := testController(t, newFakeEnv(nil), connector.SlotA, true)
	devA, err := c.PartitionFor(connector.SlotA)
	if err != nil {
		t.Fatalf("PartitionFor(A): %v", err)
	}
	if filepath.Base(devA) != "rootfsA" {
		t.Fatalf("PartitionFor(A) = %q, want .../rootfsA", devA)
	}
	devB, err := c.PartitionFor(connector.SlotB)
	if err != nil {
		t.Fatalf("PartitionFor(B): %v", err)
	}
	if filepath.Base(devB) != "rootfsB" {
		t.Fatalf("PartitionFor(B) = %q, want .../rootfsB", devB)
	}
}

func TestPartitionForMissing(t *testing.T) {
	c := testController(t, newFakeEnv(nil), connector.SlotA, false)
	if _, err := c.PartitionFor(connector.SlotA); err == nil {
		t.Fatal("PartitionFor with no labelled partition: want error, got nil")
	}
}

func TestCurrentSlot(t *testing.T) {
	for _, running := range []connector.Slot{connector.SlotA, connector.SlotB} {
		c := testController(t, newFakeEnv(nil), running, true)
		got, err := c.CurrentSlot()
		if err != nil {
			t.Fatalf("running %s: %v", running, err)
		}
		if got != running {
			t.Fatalf("CurrentSlot = %s, want %s", got, running)
		}
	}
}

func TestCurrentSlotNoMatch(t *testing.T) {
	c := testController(t, newFakeEnv(nil), -1, true)
	if _, err := c.CurrentSlot(); err == nil {
		t.Fatal("CurrentSlot with unmatched root: want error, got nil")
	}
}

// The GPT partlabel is authoritative and takes precedence over the fs label, so
// even a deliberately wrong fs label is ignored when a partlabel is present.
func TestSlotResolutionPartlabelWinsOverFSLabel(t *testing.T) {
	c := New()
	c.env = newFakeEnv(nil)
	c.RootDir = t.TempDir()
	const a, b = "/dev/nvme0n1p3", "/dev/nvme0n1p4"
	c.rootDeviceFn = func() (string, error) { return a, nil }
	c.listPartsFn = func() ([]partInfo, error) {
		return []partInfo{
			{path: a, partlabel: partlabelA, label: "bogusA", pkname: "nvme0n1"},
			{path: b, partlabel: partlabelB, label: "bogusB", pkname: "nvme0n1"},
		}, nil
	}
	if got, err := c.CurrentSlot(); err != nil || got != connector.SlotA {
		t.Fatalf("CurrentSlot = %v, %v; want A, nil", got, err)
	}
	if dev, err := c.PartitionFor(connector.SlotB); err != nil || dev != b {
		t.Fatalf("PartitionFor(B) = %q, %v; want %q", dev, err, b)
	}
}

// Reproduces the install-media + internal-disk collision: two disks both
// carrying rootfsA/rootfsB (e.g. booted from the USB stick while the NVMe holds
// its own copy). Slot resolution must stay on the disk the running root is on
// (the USB here) and never resolve to the other disk's same-labelled partitions.
func TestSlotResolutionScopedToBootDisk(t *testing.T) {
	c := New()
	c.env = newFakeEnv(nil)
	c.RootDir = t.TempDir()
	const usbA, usbB = "/dev/sda3", "/dev/sda4"
	const nvA, nvB = "/dev/nvme0n1p3", "/dev/nvme0n1p4"
	c.rootDeviceFn = func() (string, error) { return usbA, nil } // booted from USB
	c.listPartsFn = func() ([]partInfo, error) {
		return []partInfo{
			{path: usbA, partlabel: partlabelA, pkname: "sda"},
			{path: usbB, partlabel: partlabelB, pkname: "sda"},
			{path: nvA, partlabel: partlabelA, pkname: "nvme0n1"},
			{path: nvB, partlabel: partlabelB, pkname: "nvme0n1"},
		}, nil
	}
	if got, err := c.CurrentSlot(); err != nil || got != connector.SlotA {
		t.Fatalf("CurrentSlot = %v, %v; want A, nil", got, err)
	}
	if dev, err := c.PartitionFor(connector.SlotA); err != nil || dev != usbA {
		t.Fatalf("PartitionFor(A) = %q, %v; want %q (USB, not NVMe)", dev, err, usbA)
	}
	if dev, err := c.PartitionFor(connector.SlotB); err != nil || dev != usbB {
		t.Fatalf("PartitionFor(B) = %q, %v; want %q (USB, not NVMe)", dev, err, usbB)
	}
}

func TestSwapSlotInstallArmsTrial(t *testing.T) {
	env := newFakeEnv(map[string]string{envBootSlot: "0", envUpgradeAvailable: "0", envBootCount: "5"})
	c := testController(t, env, connector.SlotA, true)

	if err := c.SwapSlot(connector.SlotB, true); err != nil {
		t.Fatalf("SwapSlot install: %v", err)
	}
	if env.vars[envBootSlot] != "1" {
		t.Fatalf("boot_slot = %q, want 1", env.vars[envBootSlot])
	}
	if env.vars[envUpgradeAvailable] != "1" {
		t.Fatalf("upgrade_available = %q, want 1 (trial armed)", env.vars[envUpgradeAvailable])
	}
	if env.vars[envBootCount] != "0" {
		t.Fatalf("bootcount = %q, want 0", env.vars[envBootCount])
	}
	if env.setCalls != 1 {
		t.Fatalf("set called %d times, want 1 (atomic batch)", env.setCalls)
	}
}

func TestSwapSlotRollbackDisarms(t *testing.T) {
	env := newFakeEnv(map[string]string{envBootSlot: "1", envUpgradeAvailable: "1", envBootCount: "1"})
	c := testController(t, env, connector.SlotB, true)

	if err := c.SwapSlot(connector.SlotA, false); err != nil {
		t.Fatalf("SwapSlot rollback: %v", err)
	}
	if env.vars[envBootSlot] != "0" {
		t.Fatalf("boot_slot = %q, want 0", env.vars[envBootSlot])
	}
	if env.vars[envUpgradeAvailable] != "0" {
		t.Fatalf("upgrade_available = %q, want 0 (rollback is permanent, not a trial)", env.vars[envUpgradeAvailable])
	}
}

// SwapSlot must refuse to write the env when the ESP (/boot) is not mounted —
// grub-editenv would write a shadow copy on the rootfs that GRUB never reads,
// silently no-op'ing the slot change. A plain subdir of RootDir shares its
// st_dev with its parent, so it is not a mountpoint.
func TestSwapSlotRefusesWhenBootNotMounted(t *testing.T) {
	env := newFakeEnv(map[string]string{envBootSlot: "0", envUpgradeAvailable: "0", envBootCount: "0"})
	c := testController(t, env, connector.SlotA, true)

	if err := os.MkdirAll(filepath.Join(c.RootDir, bootMount), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := c.SwapSlot(connector.SlotB, true); err == nil {
		t.Fatal("SwapSlot armed a trial while /boot was not a mountpoint; want refusal")
	}
	if env.setCalls != 0 {
		t.Fatalf("env written %d times despite the guard; want 0", env.setCalls)
	}
}

// assertEnvWritable fails OPEN when /boot cannot be stat'd (no mount semantics
// to check), so it must not block.
func TestAssertEnvWritableFailsOpen(t *testing.T) {
	c := New()
	c.RootDir = t.TempDir() // no /boot subdir -> stat fails -> fail open
	if err := c.assertEnvWritable(); err != nil {
		t.Fatalf("missing /boot should skip the guard, got: %v", err)
	}
}

func TestPrepareTargetClearsStaleTrial(t *testing.T) {
	env := newFakeEnv(map[string]string{envUpgradeAvailable: "1", envBootCount: "1"})
	c := testController(t, env, connector.SlotA, true)
	if err := c.PrepareTarget(connector.SlotB); err != nil {
		t.Fatalf("PrepareTarget: %v", err)
	}
	if env.vars[envUpgradeAvailable] != "0" || env.vars[envBootCount] != "0" {
		t.Fatalf("PrepareTarget did not clear trial: upgrade=%q bootcount=%q",
			env.vars[envUpgradeAvailable], env.vars[envBootCount])
	}
}

func TestBootIsCompromised(t *testing.T) {
	for _, tc := range []struct {
		name     string
		armed    string
		intended string
		running  connector.Slot
		want     bool
	}{
		{"no trial armed", "0", "1", connector.SlotA, false},
		{"trial armed, running requested slot", "1", "1", connector.SlotB, false},
		{"trial armed, fell back to other slot", "1", "1", connector.SlotA, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			env := newFakeEnv(map[string]string{envUpgradeAvailable: tc.armed, envBootSlot: tc.intended})
			c := testController(t, env, tc.running, true)
			got, err := c.BootIsCompromised()
			if err != nil {
				t.Fatalf("BootIsCompromised: %v", err)
			}
			if got != tc.want {
				t.Fatalf("BootIsCompromised = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestMarkGood(t *testing.T) {
	env := newFakeEnv(map[string]string{envBootSlot: "0", envUpgradeAvailable: "1", envBootCount: "1"})
	c := testController(t, env, connector.SlotB, true) // committed onto slot B
	if err := c.MarkGood(); err != nil {
		t.Fatalf("MarkGood: %v", err)
	}
	if env.vars[envBootSlot] != "1" {
		t.Fatalf("boot_slot = %q, want 1 (pinned to running slot)", env.vars[envBootSlot])
	}
	if env.vars[envUpgradeAvailable] != "0" {
		t.Fatalf("upgrade_available = %q, want 0 (committed)", env.vars[envUpgradeAvailable])
	}
	if env.vars[envBootCount] != "0" {
		t.Fatalf("bootcount = %q, want 0", env.vars[envBootCount])
	}
}

func TestPlatformUpdateNoOps(t *testing.T) {
	c := testController(t, newFakeEnv(nil), connector.SlotA, true)
	if err := c.VerifyPlatformUpdate(true); err != nil {
		t.Fatalf("VerifyPlatformUpdate: %v", err)
	}
	if err := c.AbortPlatformUpdate(); err != nil {
		t.Fatalf("AbortPlatformUpdate: %v", err)
	}
}

func TestDiagnostics(t *testing.T) {
	env := newFakeEnv(map[string]string{envBootSlot: "1", envUpgradeAvailable: "0", envBootCount: "0"})
	c := testController(t, env, connector.SlotB, true)
	d := c.Diagnostics(false)
	if d["wendyos_boot_slot"] != "1" {
		t.Fatalf("diagnostics missing boot_slot: %v", d)
	}
	if _, ok := d["rootfsB_dev"]; ok {
		t.Fatal("non-verbose diagnostics should not include device paths")
	}
	dv := c.Diagnostics(true)
	if _, ok := dv["rootfsB_dev"]; !ok {
		t.Fatalf("verbose diagnostics missing device paths: %v", dv)
	}
}

// Ensures the connector registered itself under the expected name and that
// Select can resolve it explicitly (the path x86 images use via config.json).
func TestRegisteredAndSelectable(t *testing.T) {
	conn, err := connector.Select("grubenv")
	if err != nil {
		t.Fatalf("Select(grubenv): %v", err)
	}
	if conn.Name() != "grubenv" {
		t.Fatalf("selected connector Name = %q, want grubenv", conn.Name())
	}
}
