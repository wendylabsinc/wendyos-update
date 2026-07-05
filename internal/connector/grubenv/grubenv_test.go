package grubenv

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// fakeEnv is an in-memory grubenv for tests (the envStore seam).
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

func (f *fakeEnv) list() (map[string]string, error) {
	m := map[string]string{}
	for k, v := range f.vars {
		m[k] = v
	}
	return m, nil
}

func (f *fakeEnv) set(vars map[string]string) error {
	f.setCalls++
	for k, v := range vars {
		f.vars[k] = v
	}
	return nil
}

// testController builds a Controller wired to a fake env and a RootDir tempdir,
// with running-root forced to the given slot's device and the ESP reported as
// mounted (so writes are not refused). Pass running = -1 to leave rootDeviceFn
// returning an unmatched device. Real files behind the by-partlabel symlinks
// let PartitionFor/CurrentSlot resolve via EvalSymlinks.
func testController(t *testing.T, env *fakeEnv, running connector.Slot) *Controller {
	t.Helper()
	c := New()
	c.env = env
	c.RootDir = t.TempDir()

	devA := c.RootDir + "/dev/rootfsA"
	devB := c.RootDir + "/dev/rootfsB"
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
	// ESP is mounted: assertEnvWritable must not refuse.
	c.mountpointFn = func(string) (bool, error) { return true, nil }
	return c
}

func TestName(t *testing.T) {
	if New().Name() != "grubenv" {
		t.Fatalf("Name = %q, want grubenv", New().Name())
	}
}

func TestSlotOtherAndString(t *testing.T) {
	if connector.SlotA.Other() != connector.SlotB || connector.SlotB.Other() != connector.SlotA {
		t.Fatal("Other() mapping wrong")
	}
	if connector.SlotA.String() != "A" || connector.SlotB.String() != "B" {
		t.Fatal("String() mapping wrong")
	}
}

func TestKeyHelpers(t *testing.T) {
	if okKey(connector.SlotA) != "A_OK" || tryKey(connector.SlotA) != "A_TRY" {
		t.Fatalf("A keys wrong: %q %q", okKey(connector.SlotA), tryKey(connector.SlotA))
	}
	if okKey(connector.SlotB) != "B_OK" || tryKey(connector.SlotB) != "B_TRY" {
		t.Fatalf("B keys wrong: %q %q", okKey(connector.SlotB), tryKey(connector.SlotB))
	}
	if orderValue(connector.SlotB) != "B A" || orderValue(connector.SlotA) != "A B" {
		t.Fatalf("orderValue wrong: %q %q", orderValue(connector.SlotB), orderValue(connector.SlotA))
	}
}

func TestOrderHeadSlot(t *testing.T) {
	for _, tc := range []struct {
		order string
		want  connector.Slot
		ok    bool
	}{
		{"A B", connector.SlotA, true},
		{"B A", connector.SlotB, true},
		{"  B   A ", connector.SlotB, true},
		{"", 0, false},
		{"X Y", 0, false},
	} {
		got, ok := orderHeadSlot(tc.order)
		if ok != tc.ok || (ok && got != tc.want) {
			t.Errorf("orderHeadSlot(%q) = %v,%v; want %v,%v", tc.order, got, ok, tc.want, tc.ok)
		}
	}
}

func TestPartitionFor(t *testing.T) {
	c := testController(t, newFakeEnv(nil), connector.SlotA)
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
	c := New()
	c.RootDir = t.TempDir() // no by-partlabel symlinks; lsblk won't list our fakes
	if _, err := c.PartitionFor(connector.SlotA); err == nil {
		t.Fatal("PartitionFor with no labelled partition: want error, got nil")
	}
}

func TestCurrentSlot(t *testing.T) {
	for _, running := range []connector.Slot{connector.SlotA, connector.SlotB} {
		c := testController(t, newFakeEnv(nil), running)
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
	c := testController(t, newFakeEnv(nil), -1)
	if _, err := c.CurrentSlot(); err == nil {
		t.Fatal("CurrentSlot with unmatched root: want error, got nil")
	}
}

// CurrentSlot must NOT read the grubenv: even a grubenv that points ORDER at
// the wrong slot must be ignored — the running root device is ground truth.
func TestCurrentSlotIgnoresGrubenv(t *testing.T) {
	env := newFakeEnv(map[string]string{envOrder: "B A"}) // env says B...
	c := testController(t, env, connector.SlotA)          // ...but A is running
	got, err := c.CurrentSlot()
	if err != nil || got != connector.SlotA {
		t.Fatalf("CurrentSlot = %v,%v; want A (from running root, not ORDER)", got, err)
	}
}

func TestSwapSlotInstallArmsTrial(t *testing.T) {
	env := newFakeEnv(map[string]string{envOrder: "A B", "A_OK": "1", "B_TRY": "1"})
	c := testController(t, env, connector.SlotA)

	if err := c.SwapSlot(connector.SlotB, true); err != nil {
		t.Fatalf("SwapSlot install: %v", err)
	}
	if env.vars[envOrder] != "B A" {
		t.Fatalf("ORDER = %q, want \"B A\"", env.vars[envOrder])
	}
	if env.vars["B_OK"] != "1" {
		t.Fatalf("B_OK = %q, want 1", env.vars["B_OK"])
	}
	if env.vars["B_TRY"] != "0" {
		t.Fatalf("B_TRY = %q, want 0 (grub.cfg sets it to 1 at boot)", env.vars["B_TRY"])
	}
	if env.vars["A_OK"] != "1" {
		t.Fatalf("A_OK = %q, want 1 (fallback target must stay good)", env.vars["A_OK"])
	}
	if env.setCalls != 1 {
		t.Fatalf("set called %d times, want 1 (atomic batch)", env.setCalls)
	}
}

func TestSwapSlotRollbackRepoints(t *testing.T) {
	env := newFakeEnv(map[string]string{envOrder: "B A", "B_OK": "1", "A_OK": "1"})
	c := testController(t, env, connector.SlotB)

	if err := c.SwapSlot(connector.SlotA, false); err != nil {
		t.Fatalf("SwapSlot rollback: %v", err)
	}
	if env.vars[envOrder] != "A B" {
		t.Fatalf("ORDER = %q, want \"A B\" (rollback re-points to A)", env.vars[envOrder])
	}
	if env.vars["A_OK"] != "1" || env.vars["A_TRY"] != "0" {
		t.Fatalf("A not made the good default: A_OK=%q A_TRY=%q", env.vars["A_OK"], env.vars["A_TRY"])
	}
}

// SwapSlot must refuse when the ESP is not mounted: grub-editenv would write a
// shadow grubenv on the rootfs that GRUB never reads, silently no-op'ing the
// slot change (the ubootenv /boot `nofail` trap, ported).
func TestSwapSlotRefusesWhenESPNotMounted(t *testing.T) {
	env := newFakeEnv(map[string]string{envOrder: "A B"})
	c := testController(t, env, connector.SlotA)
	// ESP not mounted anywhere above the grubenv: a clean "not a mountpoint".
	c.mountpointFn = func(string) (bool, error) { return false, nil }

	if err := c.SwapSlot(connector.SlotB, true); err == nil {
		t.Fatal("SwapSlot armed a trial while the ESP was not mounted; want refusal")
	}
	if env.setCalls != 0 {
		t.Fatalf("env written %d times despite the guard; want 0", env.setCalls)
	}
}

// assertEnvWritable fails OPEN when it cannot determine anything (only stat
// errors from the mountpoint probe): it must not block on an environment it
// cannot read.
func TestAssertEnvWritableFailsOpen(t *testing.T) {
	c := testController(t, newFakeEnv(nil), connector.SlotA)
	c.mountpointFn = func(string) (bool, error) { return false, os.ErrNotExist }
	if err := c.assertEnvWritable(); err != nil {
		t.Fatalf("only stat errors should fail open, got: %v", err)
	}
}

// assertEnvWritable passes as soon as a real sub-mount (the ESP) is found above
// the grubenv, even if deeper directories are not mountpoints.
func TestAssertEnvWritablePassesWhenESPMounted(t *testing.T) {
	c := New()
	c.EnvPath = "/boot/efi/EFI/wendyos/grubenv"
	// Only /boot/efi is a mountpoint; the deeper EFI/wendyos dirs are not.
	c.mountpointFn = func(path string) (bool, error) {
		return path == "/boot/efi", nil
	}
	if err := c.assertEnvWritable(); err != nil {
		t.Fatalf("ESP mounted at /boot/efi should pass, got: %v", err)
	}
}

func TestPrepareTargetClearsStaleTrial(t *testing.T) {
	env := newFakeEnv(map[string]string{"B_TRY": "1", "B_OK": "1"})
	c := testController(t, env, connector.SlotA)
	if err := c.PrepareTarget(connector.SlotB); err != nil {
		t.Fatalf("PrepareTarget: %v", err)
	}
	if env.vars["B_TRY"] != "0" {
		t.Fatalf("B_TRY = %q, want 0 (stale trial cleared)", env.vars["B_TRY"])
	}
}

func TestMarkGood(t *testing.T) {
	env := newFakeEnv(map[string]string{envOrder: "A B", "B_TRY": "1", "A_OK": "1"})
	c := testController(t, env, connector.SlotB) // committed onto slot B
	if err := c.MarkGood(); err != nil {
		t.Fatalf("MarkGood: %v", err)
	}
	if env.vars[envOrder] != "B A" {
		t.Fatalf("ORDER = %q, want \"B A\" (pinned to running slot)", env.vars[envOrder])
	}
	if env.vars["B_OK"] != "1" || env.vars["B_TRY"] != "0" {
		t.Fatalf("running slot not confirmed: B_OK=%q B_TRY=%q", env.vars["B_OK"], env.vars["B_TRY"])
	}
	if env.vars["A_OK"] != "1" {
		t.Fatalf("A_OK = %q, want 1 (inactive slot stays a rollback target)", env.vars["A_OK"])
	}
}

func TestBootIsCompromised(t *testing.T) {
	for _, tc := range []struct {
		name    string
		order   string
		running connector.Slot
		want    bool
	}{
		{"running the ordered head", "B A", connector.SlotB, false},
		{"fell back to the other slot", "B A", connector.SlotA, true},
		{"no order set", "", connector.SlotA, false},
		{"committed steady state", "A B", connector.SlotA, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			env := newFakeEnv(map[string]string{envOrder: tc.order})
			c := testController(t, env, tc.running)
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
	c := testController(t, newFakeEnv(nil), connector.SlotA)
	if err := c.VerifyPlatformUpdate(true); err != nil {
		t.Fatalf("VerifyPlatformUpdate: %v", err)
	}
	if err := c.AbortPlatformUpdate(); err != nil {
		t.Fatalf("AbortPlatformUpdate: %v", err)
	}
}

func TestDiagnostics(t *testing.T) {
	env := newFakeEnv(map[string]string{envOrder: "B A", "B_OK": "1", "B_TRY": "0", "A_OK": "1"})
	c := testController(t, env, connector.SlotB)
	d := c.Diagnostics(false)
	if d[envOrder] != "B A" || d["B_OK"] != "1" {
		t.Fatalf("diagnostics missing grubenv vars: %v", d)
	}
	if _, ok := d["rootfsB_dev"]; ok {
		t.Fatal("non-verbose diagnostics should not include device paths")
	}
	dv := c.Diagnostics(true)
	if _, ok := dv["rootfsB_dev"]; !ok {
		t.Fatalf("verbose diagnostics missing device paths: %v", dv)
	}
}

func TestSlotStatus(t *testing.T) {
	env := newFakeEnv(map[string]string{"A_OK": "1", "A_TRY": "0", "B_OK": "1", "B_TRY": "1"})
	c := testController(t, env, connector.SlotA)
	if note := c.SlotStatus(connector.SlotA).Note; note != "known-good" {
		t.Fatalf("SlotStatus(A).Note = %q, want known-good", note)
	}
	if note := c.SlotStatus(connector.SlotB).Note; note != "trial armed" {
		t.Fatalf("SlotStatus(B).Note = %q, want trial armed", note)
	}
}

func TestSystemStatusNil(t *testing.T) {
	c := testController(t, newFakeEnv(nil), connector.SlotA)
	if c.SystemStatus() != nil {
		t.Fatal("SystemStatus should be nil for grub boards")
	}
}

// Ensures the connector registered itself under the expected name and that
// Select can resolve it explicitly (the path Jetson GRUB images use via
// config.json).
func TestRegisteredAndSelectable(t *testing.T) {
	conn, err := connector.Select("grubenv")
	if err != nil {
		t.Fatalf("Select(grubenv): %v", err)
	}
	if conn.Name() != "grubenv" {
		t.Fatalf("selected connector Name = %q, want grubenv", conn.Name())
	}
}

// fakeGrubEditenv writes an executable stub that emulates grub-editenv's
// <path> {create|set|list} subcommands against a plain-text file, and records
// every invocation's args to logPath — like tegrauefi's recordingNvbootctrl, so
// a test can assert the exact commands the connector issued and read them back.
func fakeGrubEditenv(t *testing.T, logPath string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "grub-editenv")
	script := "#!/bin/sh\n" +
		"envfile=\"$1\"; shift\n" +
		"cmd=\"$1\"; shift\n" +
		"echo \"$cmd $*\" >> '" + logPath + "'\n" +
		"case \"$cmd\" in\n" +
		"  create) : > \"$envfile\" ;;\n" +
		"  set)\n" +
		"    for kv in \"$@\"; do\n" +
		"      key=\"${kv%%=*}\"\n" +
		"      if [ -f \"$envfile\" ]; then grep -v \"^${key}=\" \"$envfile\" > \"$envfile.tmp\" 2>/dev/null; mv \"$envfile.tmp\" \"$envfile\"; fi\n" +
		"      echo \"$kv\" >> \"$envfile\"\n" +
		"    done ;;\n" +
		"  list) cat \"$envfile\" 2>/dev/null ;;\n" +
		"esac\n" +
		"exit 0\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// Exercises the real grub-editenv shell-out path (the grubEnv envStore) via a
// stub script: SwapSlot must invoke `grub-editenv <path> set ...` with the
// grubenv path as the first argument and "KEY=VALUE" tokens, and a subsequent
// list must read those values back.
func TestGrubEditenvShellOut(t *testing.T) {
	tmp := t.TempDir()
	logPath := filepath.Join(tmp, "calls.log")
	envPath := filepath.Join(tmp, "grubenv")

	c := New()
	c.RootDir = t.TempDir()
	c.GrubEditenv = fakeGrubEditenv(t, logPath)
	c.EnvPath = envPath
	c.env = grubEnv{bin: c.GrubEditenv, path: envPath}
	c.mountpointFn = func(string) (bool, error) { return true, nil }
	// Resolve slots by-partlabel under RootDir, running slot A.
	devA := c.RootDir + "/dev/rootfsA"
	devB := c.RootDir + "/dev/rootfsB"
	if err := os.MkdirAll(c.RootDir+"/dev/disk/by-partlabel", 0o755); err != nil {
		t.Fatal(err)
	}
	for _, d := range []string{devA, devB} {
		if err := os.WriteFile(d, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(devA, c.RootDir+"/dev/disk/by-partlabel/"+partlabelA); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(devB, c.RootDir+"/dev/disk/by-partlabel/"+partlabelB); err != nil {
		t.Fatal(err)
	}
	c.rootDeviceFn = func() (string, error) { return devA, nil }

	if err := c.SwapSlot(connector.SlotB, true); err != nil {
		t.Fatalf("SwapSlot: %v", err)
	}

	log, _ := os.ReadFile(logPath)
	logs := string(log)
	if !strings.Contains(logs, "set ") {
		t.Fatalf("grub-editenv set was not invoked; calls:\n%s", logs)
	}
	for _, want := range []string{"B_OK=1", "B_TRY=0", "ORDER=B A"} {
		if !strings.Contains(logs, want) {
			t.Fatalf("grub-editenv set missing %q; calls:\n%s", want, logs)
		}
	}

	// Read back through the same stub: values must round-trip.
	m, err := c.env.list()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if m["B_OK"] != "1" || m["B_TRY"] != "0" || m[envOrder] != "B A" {
		t.Fatalf("round-trip mismatch: %v", m)
	}
}
