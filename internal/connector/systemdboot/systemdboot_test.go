package systemdboot

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// recordingBootctl writes a stub `bootctl` that appends every invocation's args
// to logPath and exits 0, so a test can assert which subcommands ran (the
// set-default/set-oneshot EFI-var writes).
func recordingBootctl(t *testing.T, logPath string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "bootctl")
	script := "#!/bin/sh\necho \"$*\" >> '" + logPath + "'\nexit 0\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// testController wires a Controller to a tempdir ESP (with loader/entries and a
// base entry per slot), a recording bootctl, by-partlabel symlinks so
// PartitionFor resolves, and rootDeviceFn pinned to the given running slot. The
// injected mountFn returns a fake rootfs carrying boot/Image + boot/initrd so
// the install path's kernel staging succeeds.
func testController(t *testing.T, running connector.Slot) (*Controller, string) {
	t.Helper()
	c := New()
	c.RootDir = t.TempDir()
	c.ESPDir = filepath.Join(t.TempDir(), "esp")

	if err := os.MkdirAll(c.entriesDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	// Base (committed) entry per slot.
	for _, letter := range []string{"a", "b"} {
		writeEntry(t, c, entryBase(letter))
	}

	// by-partlabel symlinks APP/APP_b -> fake dev files under RootDir.
	linkDir := filepath.Join(c.RootDir, "dev", "disk", "by-partlabel")
	if err := os.MkdirAll(linkDir, 0o755); err != nil {
		t.Fatal(err)
	}
	devFor := map[connector.Slot]string{}
	for _, s := range []connector.Slot{connector.SlotA, connector.SlotB} {
		label := partlabelFor(s)
		dev := filepath.Join(c.RootDir, "fake-"+label)
		if err := os.WriteFile(dev, nil, 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(dev, filepath.Join(linkDir, label)); err != nil {
			t.Fatal(err)
		}
		devFor[s] = dev
	}
	c.rootDeviceFn = func() (string, error) { return devFor[running], nil }

	// Fake target rootfs mount with a kernel + initrd to stage.
	c.mountFn = func(string) (string, func(), error) {
		mnt := t.TempDir()
		if err := os.MkdirAll(filepath.Join(mnt, "boot"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(mnt, "boot", "Image"), []byte("kernel"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(mnt, "boot", "initrd"), []byte("initrd"), 0o644); err != nil {
			t.Fatal(err)
		}
		return mnt, func() {}, nil
	}

	logPath := filepath.Join(t.TempDir(), "bootctl.log")
	c.Bootctl = recordingBootctl(t, logPath)
	return c, logPath
}

func writeEntry(t *testing.T, c *Controller, filename string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(c.entriesDir(), filename), []byte("title WendyOS\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// entryFilename returns the single loader entry file name for a slot, failing if
// zero or many match — a small assertion helper for the tests below.
func entryFilename(t *testing.T, c *Controller, s connector.Slot) string {
	t.Helper()
	e, err := c.findEntry(slotLetter(s))
	if err != nil {
		t.Fatalf("findEntry(%s): %v", s, err)
	}
	return filepath.Base(e.path)
}

func TestName(t *testing.T) {
	if New().Name() != "systemdboot" {
		t.Fatalf("Name = %q, want systemdboot", New().Name())
	}
}

func TestRegisteredAndSelectable(t *testing.T) {
	conn, err := connector.Select("systemdboot")
	if err != nil {
		t.Fatalf("Select(systemdboot): %v", err)
	}
	if conn.Name() != "systemdboot" {
		t.Fatalf("selected connector Name = %q, want systemdboot", conn.Name())
	}
}

func TestCurrentSlot(t *testing.T) {
	for _, running := range []connector.Slot{connector.SlotA, connector.SlotB} {
		c, _ := testController(t, running)
		got, err := c.CurrentSlot()
		if err != nil {
			t.Fatalf("running %s: %v", running, err)
		}
		if got != running {
			t.Fatalf("CurrentSlot = %s, want %s", got, running)
		}
	}
}

func TestPartitionFor(t *testing.T) {
	c, _ := testController(t, connector.SlotA)
	devA, err := c.PartitionFor(connector.SlotA)
	if err != nil || filepath.Base(devA) != "fake-APP" {
		t.Fatalf("PartitionFor(A) = %q, %v; want .../fake-APP", devA, err)
	}
	devB, err := c.PartitionFor(connector.SlotB)
	if err != nil || filepath.Base(devB) != "fake-APP_b" {
		t.Fatalf("PartitionFor(B) = %q, %v; want .../fake-APP_b", devB, err)
	}
}

// SwapSlot install must stage the new slot's kernel onto the ESP, arm the trial
// counter (+3) on its entry, and point LoaderEntryDefault at it.
func TestSwapSlotInstallStagesAndArmsTrial(t *testing.T) {
	c, logPath := testController(t, connector.SlotA) // running A, installing to B

	if err := c.SwapSlot(connector.SlotB, true); err != nil {
		t.Fatalf("SwapSlot install: %v", err)
	}

	if got := entryFilename(t, c, connector.SlotB); got != "slot-b+3.conf" {
		t.Fatalf("slot B entry = %q, want slot-b+3.conf (trial armed)", got)
	}
	// Kernel + initrd staged onto the ESP under /b/.
	for _, f := range []string{"b/Image", "b/initrd"} {
		if _, err := os.Stat(filepath.Join(c.ESPDir, f)); err != nil {
			t.Fatalf("expected staged %s on ESP: %v", f, err)
		}
	}
	calls, _ := os.ReadFile(logPath)
	if !strings.Contains(string(calls), "set-default slot-b") {
		t.Fatalf("expected bootctl set-default slot-b; calls were:\n%s", calls)
	}
}

// SwapSlot rollback is a pure re-point: drop the target's counter (permanent) and
// set it default. It must NOT mount/stage.
func TestSwapSlotRollbackDropsCounter(t *testing.T) {
	c, logPath := testController(t, connector.SlotB) // running B, rolling back to A
	// Arm a stale trial on A first.
	if err := os.Rename(filepath.Join(c.entriesDir(), "slot-a.conf"),
		filepath.Join(c.entriesDir(), "slot-a+2-1.conf")); err != nil {
		t.Fatal(err)
	}
	// Fail the mount to prove rollback never stages.
	c.mountFn = func(string) (string, func(), error) {
		t.Fatal("rollback must not mount the target rootfs")
		return "", nil, nil
	}

	if err := c.SwapSlot(connector.SlotA, false); err != nil {
		t.Fatalf("SwapSlot rollback: %v", err)
	}
	if got := entryFilename(t, c, connector.SlotA); got != "slot-a.conf" {
		t.Fatalf("slot A entry = %q, want slot-a.conf (counter dropped)", got)
	}
	calls, _ := os.ReadFile(logPath)
	if !strings.Contains(string(calls), "set-default slot-a") {
		t.Fatalf("expected bootctl set-default slot-a; calls were:\n%s", calls)
	}
}

// PrepareTarget rehabilitates a slot whose entry ran out of tries (bad), so it
// can be booted again — the analogue of resetting Tegra's 0xFF unbootable status.
func TestPrepareTargetRehabilitatesBadEntry(t *testing.T) {
	c, _ := testController(t, connector.SlotA)
	if err := os.Rename(filepath.Join(c.entriesDir(), "slot-b.conf"),
		filepath.Join(c.entriesDir(), "slot-b+0-3.conf")); err != nil {
		t.Fatal(err)
	}
	if err := c.PrepareTarget(connector.SlotB); err != nil {
		t.Fatalf("PrepareTarget: %v", err)
	}
	if got := entryFilename(t, c, connector.SlotB); got != "slot-b.conf" {
		t.Fatalf("slot B entry = %q, want slot-b.conf (rehabilitated)", got)
	}
}

func TestPrepareTargetNoOpOnGood(t *testing.T) {
	c, _ := testController(t, connector.SlotA)
	if err := c.PrepareTarget(connector.SlotB); err != nil {
		t.Fatalf("PrepareTarget: %v", err)
	}
	if got := entryFilename(t, c, connector.SlotB); got != "slot-b.conf" {
		t.Fatalf("slot B entry = %q, want unchanged slot-b.conf", got)
	}
}

func TestPrepareTargetMissingEntryErrors(t *testing.T) {
	c, _ := testController(t, connector.SlotA)
	if err := os.Remove(filepath.Join(c.entriesDir(), "slot-b.conf")); err != nil {
		t.Fatal(err)
	}
	if err := c.PrepareTarget(connector.SlotB); err == nil {
		t.Fatal("PrepareTarget with no entry: want error, got nil")
	}
}

// MarkGood commits the running slot: drop its counter and set it default.
func TestMarkGoodCommitsRunningSlot(t *testing.T) {
	c, logPath := testController(t, connector.SlotB) // committed onto B
	// B is mid-trial.
	if err := os.Rename(filepath.Join(c.entriesDir(), "slot-b.conf"),
		filepath.Join(c.entriesDir(), "slot-b+2-1.conf")); err != nil {
		t.Fatal(err)
	}
	if err := c.MarkGood(); err != nil {
		t.Fatalf("MarkGood: %v", err)
	}
	if got := entryFilename(t, c, connector.SlotB); got != "slot-b.conf" {
		t.Fatalf("slot B entry = %q, want slot-b.conf (blessed)", got)
	}
	calls, _ := os.ReadFile(logPath)
	if !strings.Contains(string(calls), "set-default slot-b") {
		t.Fatalf("expected bootctl set-default slot-b; calls were:\n%s", calls)
	}
}

func TestBootIsCompromised(t *testing.T) {
	for _, tc := range []struct {
		name      string
		running   connector.Slot
		trialSlot connector.Slot // which slot to arm; -1 = none
		want      bool
	}{
		{"no trial armed", connector.SlotA, -1, false},
		{"trial armed, running trial slot", connector.SlotB, connector.SlotB, false},
		{"trial armed, fell back to other slot", connector.SlotA, connector.SlotB, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, _ := testController(t, tc.running)
			if tc.trialSlot >= 0 {
				letter := slotLetter(tc.trialSlot)
				if err := os.Rename(filepath.Join(c.entriesDir(), entryBase(letter)),
					filepath.Join(c.entriesDir(), counterFilename(letter, 0, 3))); err != nil {
					t.Fatal(err)
				}
			}
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

func TestPlatformUpdateNoOps(t *testing.T) {
	c, _ := testController(t, connector.SlotA)
	if err := c.VerifyPlatformUpdate(true); err != nil {
		t.Fatalf("VerifyPlatformUpdate: %v", err)
	}
	if err := c.AbortPlatformUpdate(); err != nil {
		t.Fatalf("AbortPlatformUpdate: %v", err)
	}
}

func TestSwapSlotErrorsWhenESPAbsent(t *testing.T) {
	c, _ := testController(t, connector.SlotA)
	if err := os.RemoveAll(c.entriesDir()); err != nil {
		t.Fatal(err)
	}
	if err := c.SwapSlot(connector.SlotB, true); err == nil {
		t.Fatal("SwapSlot with no ESP loader entries: want error, got nil")
	}
}

func TestDiagnosticsAndSlotStatus(t *testing.T) {
	c, _ := testController(t, connector.SlotA)
	// Arm a trial on B so the status surfaces a retry budget.
	if err := os.Rename(filepath.Join(c.entriesDir(), "slot-b.conf"),
		filepath.Join(c.entriesDir(), "slot-b+3.conf")); err != nil {
		t.Fatal(err)
	}

	d := c.Diagnostics(false)
	if d["rootfs_slot"] != "A" {
		t.Fatalf("diagnostics rootfs_slot = %q, want A", d["rootfs_slot"])
	}
	if d["trial_slot"] != "B" {
		t.Fatalf("diagnostics trial_slot = %q, want B", d["trial_slot"])
	}
	if _, ok := d["esp"]; ok {
		t.Fatal("non-verbose diagnostics should not include esp path")
	}
	if _, ok := c.Diagnostics(true)["esp"]; !ok {
		t.Fatal("verbose diagnostics missing esp path")
	}

	st := c.SlotStatus(connector.SlotB)
	if st.RootfsHealth != "normal" || st.Retries != "3" || st.Note == "" {
		t.Fatalf("SlotStatus(B) = %+v, want normal/3/trial-note", st)
	}
	if got := c.SlotStatus(connector.SlotA); got.RootfsHealth != "normal" {
		t.Fatalf("SlotStatus(A) = %+v, want normal", got)
	}
}
