package tegrauefi

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// fakeNvbootctrl writes an executable stub that prints the given
// stdout for any invocation and returns its path.
func fakeNvbootctrl(t *testing.T, stdout string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "nvbootctrl")
	script := "#!/bin/sh\nprintf '%s' '" + stdout + "'\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// recordingNvbootctrl writes a stub that appends every invocation's args to
// logPath, answers get-current-slot with currentSlotOut, and exits 0 for
// anything else — so a test can assert which subcommands were run.
func recordingNvbootctrl(t *testing.T, logPath, currentSlotOut string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "nvbootctrl")
	script := "#!/bin/sh\n" +
		"echo \"$*\" >> '" + logPath + "'\n" +
		"case \"$*\" in *get-current-slot*) printf '%s' '" + currentSlotOut + "';; esac\n" +
		"exit 0\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func testController(t *testing.T) *Controller {
	t.Helper()
	c := New()
	c.EfivarsDir = t.TempDir()
	c.RootDir = t.TempDir()
	return c
}

// ConfirmBoot is the per-boot confirm behind connector.BootConfirmer: it must
// run `nvbootctrl -t rootfs mark-boot-successful`, which stops UEFI's rootfs
// A/B boot-validation watchdog and retry countdown for the running slot.
func TestConfirmBootRunsMarkBootSuccessful(t *testing.T) {
	c := testController(t)
	logPath := filepath.Join(t.TempDir(), "calls.log")
	c.Nvbootctrl = recordingNvbootctrl(t, logPath, "0\n")

	if err := c.ConfirmBoot(); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(logPath)
	if !strings.Contains(string(data), "-t rootfs mark-boot-successful") {
		t.Fatalf("ConfirmBoot did not run mark-boot-successful; calls were:\n%s", data)
	}
}

// MarkGood must confirm the running slot to the bootloader
// (nvbootctrl mark-boot-successful) — the trial-boot confirm that stops the
// firmware retry countdown. WendyOS does not ship NVIDIA's
// nv_update_verifier.service, so if the tool skips this the firmware A/B
// fallback never completes: committed slots are never confirmed, and a slot
// that dies before userspace never triggers the intended fallback.
func TestMarkGoodConfirmsBootToFirmware(t *testing.T) {
	c := testController(t)
	logPath := filepath.Join(t.TempDir(), "calls.log")
	c.Nvbootctrl = recordingNvbootctrl(t, logPath, "0\n") // running slot A

	if err := c.MarkGood(); err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(logPath)
	if !strings.Contains(string(data), "-t rootfs mark-boot-successful") {
		t.Fatalf("MarkGood did not confirm the boot via nvbootctrl mark-boot-successful; calls were:\n%s", data)
	}
}

func writeSlotVar(t *testing.T, c *Controller, s connector.Slot, content []byte) string {
	t.Helper()
	path := c.statusVar(s)
	if err := os.WriteFile(path, content, 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// armed rootfs A/B redundancy is 4-byte attrs (0x07) + a non-zero UINT32
// level, exactly as scripts/system-status.sh --dual writes it.
var redundancyArmed = []byte{0x07, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00}

func writeRedundancyVar(t *testing.T, c *Controller, content []byte) {
	t.Helper()
	if err := os.WriteFile(c.redundancyLevelVar(), content, 0o644); err != nil {
		t.Fatal(err)
	}
}

// PreflightInstall must REFUSE when rootfs A/B redundancy is not armed: the
// RootfsRedundancyLevel variable is missing (the state a raw NVMe rootfs flash
// leaves, vs tegraflash which arms it). Otherwise the slot switch is a silent
// firmware no-op and the update rolls back at commit.
func TestPreflightInstallRefusesWhenRedundancyNotArmed(t *testing.T) {
	// Missing variable entirely.
	c := testController(t)
	if err := c.PreflightInstall(); err == nil {
		t.Fatal("PreflightInstall should refuse when RootfsRedundancyLevel is absent")
	} else if !strings.Contains(err.Error(), "RootfsRedundancyLevel") {
		t.Fatalf("error should name the missing variable; got: %v", err)
	}

	// Present but zero level (single-slot) — also not armed.
	c = testController(t)
	writeRedundancyVar(t, c, []byte{0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00})
	if err := c.PreflightInstall(); err == nil {
		t.Fatal("PreflightInstall should refuse when RootfsRedundancyLevel level is zero")
	}
}

// PreflightInstall must PASS when redundancy is armed, so a correctly
// provisioned device (e.g. the AGX Orin, or an Orin Nano after --dual) updates
// normally.
func TestPreflightInstallPassesWhenRedundancyArmed(t *testing.T) {
	c := testController(t)
	writeRedundancyVar(t, c, redundancyArmed)
	if err := c.PreflightInstall(); err != nil {
		t.Fatalf("PreflightInstall should pass when redundancy is armed; got: %v", err)
	}
}

// fakeSoC writes a device-tree "compatible" property under the controller's
// RootDir so the SoC gates (bootChainSlotAB / capsuleUpdateEffective) resolve.
// compatible is a NUL-separated list of "vendor,soc" strings.
func fakeSoC(t *testing.T, c *Controller, soc string) {
	t.Helper()
	dir := filepath.Join(c.RootDir, "proc", "device-tree")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	compat := "nvidia,board\x00nvidia," + soc + "\x00"
	if err := os.WriteFile(filepath.Join(dir, "compatible"), []byte(compat), 0o644); err != nil {
		t.Fatal(err)
	}
}

// On Orin (tegra234) the rootfs-redundancy layer is unarmable from the OS, so
// the connector drives the coupled BOOT CHAIN instead: nvbootctrl WITHOUT
// `-t rootfs`. Thor (tegra264) and any unknown SoC keep the rootfs-redundancy
// layer (`-t rootfs`).
func TestBootChainModeBySoC(t *testing.T) {
	for _, tc := range []struct {
		name      string
		soc       string // "" = no compatible file (unknown SoC)
		bootChain bool
	}{
		{"orin t234 -> boot chain", "tegra234", true},
		{"thor t264 -> rootfs redundancy", "tegra264", false},
		{"unknown SoC -> rootfs redundancy", "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := testController(t)
			if tc.soc != "" {
				fakeSoC(t, c, tc.soc)
			}
			if got := c.bootChainSlotAB(); got != tc.bootChain {
				t.Fatalf("bootChainSlotAB = %v, want %v", got, tc.bootChain)
			}
			args := strings.Join(c.nvbootctrlSlotArgs(), " ")
			wantRootfs := !tc.bootChain
			if strings.Contains(args, "-t rootfs") != wantRootfs {
				t.Fatalf("nvbootctrlSlotArgs = %q; want -t rootfs present=%v", args, wantRootfs)
			}
		})
	}
}

// The fix for the original Orin failure: a slot switch on Orin must go to the
// boot chain (no `-t rootfs`), which flips the coupled rootfs slot without the
// unarmable RootfsRedundancyLevel var. Thor keeps `-t rootfs`.
func TestSwapSlotRollbackTargetsCorrectNvbootctrlLayer(t *testing.T) {
	for _, tc := range []struct {
		name       string
		soc        string
		wantRootfs bool
	}{
		{"orin uses boot chain", "tegra234", false},
		{"thor uses rootfs redundancy", "tegra264", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := testController(t)
			fakeSoC(t, c, tc.soc)
			logPath := filepath.Join(t.TempDir(), "calls.log")
			c.Nvbootctrl = recordingNvbootctrl(t, logPath, "0\n")

			// rollback path (stagePlatformUpdate=false): pure nvbootctrl re-point.
			if err := c.SwapSlot(connector.SlotB, false); err != nil {
				t.Fatalf("SwapSlot rollback: %v", err)
			}
			data, _ := os.ReadFile(logPath)
			if !strings.Contains(string(data), "set-active-boot-slot 1") {
				t.Fatalf("SwapSlot did not set-active-boot-slot 1; calls:\n%s", data)
			}
			if strings.Contains(string(data), "-t rootfs") != tc.wantRootfs {
				t.Fatalf("SwapSlot -t rootfs present=%v, want %v; calls:\n%s",
					strings.Contains(string(data), "-t rootfs"), tc.wantRootfs, data)
			}
		})
	}
}

// On Orin, boot-chain A/B needs no RootfsRedundancyLevel, so PreflightInstall
// must PASS even though the var is absent — the exact state that (correctly)
// blocks on the rootfs-redundancy path.
func TestPreflightInstallPassesOnBootChainOrin(t *testing.T) {
	c := testController(t) // RootDir has no RootfsRedundancyLevel var
	fakeSoC(t, c, "tegra234")
	if err := c.PreflightInstall(); err != nil {
		t.Fatalf("PreflightInstall should pass on Orin (boot-chain A/B, no redundancy var needed); got: %v", err)
	}
}

// CurrentSlot on Orin reads the boot-chain slot (no `-t rootfs`); the coupled
// rootfs slot is the same value.
func TestCurrentSlotUsesBootChainOnOrin(t *testing.T) {
	c := testController(t)
	fakeSoC(t, c, "tegra234")
	logPath := filepath.Join(t.TempDir(), "calls.log")
	c.Nvbootctrl = recordingNvbootctrl(t, logPath, "1\n")

	got, err := c.CurrentSlot()
	if err != nil || got != connector.SlotB {
		t.Fatalf("CurrentSlot = %v, %v; want B, nil", got, err)
	}
	data, _ := os.ReadFile(logPath)
	if strings.Contains(string(data), "-t rootfs") {
		t.Fatalf("CurrentSlot used -t rootfs on Orin (want boot chain); calls:\n%s", data)
	}
}

func TestSlotOther(t *testing.T) {
	if connector.SlotA.Other() != connector.SlotB || connector.SlotB.Other() != connector.SlotA {
		t.Fatal("Other() mapping wrong")
	}
	if connector.SlotA.String() != "A" || connector.SlotB.String() != "B" {
		t.Fatal("String() mapping wrong")
	}
}

func TestCurrentSlot(t *testing.T) {
	for _, tc := range []struct {
		out  string
		want connector.Slot
		err  bool
	}{
		{"0\n", connector.SlotA, false},
		{"1\n", connector.SlotB, false},
		{"2\n", 0, true},
		{"garbage", 0, true},
	} {
		c := testController(t)
		c.Nvbootctrl = fakeNvbootctrl(t, tc.out)
		got, err := c.CurrentSlot()
		if tc.err != (err != nil) {
			t.Fatalf("out=%q: err=%v, want err=%v", tc.out, err, tc.err)
		}
		if !tc.err && got != tc.want {
			t.Fatalf("out=%q: got slot %v, want %v", tc.out, got, tc.want)
		}
	}
}

func TestSplitPartDev(t *testing.T) {
	for _, tc := range []struct {
		dev  string
		base string
		num  int
		err  bool
	}{
		{"/dev/nvme0n1p2", "/dev/nvme0n1", 2, false},
		{"/dev/mmcblk0p1", "/dev/mmcblk0", 1, false},
		{"/dev/nvme0n1p17", "/dev/nvme0n1", 17, false},
		{"/dev/sda2", "", 0, true}, // no 'p' separator scheme
		{"/dev/nvme0n1p", "", 0, true},
	} {
		base, num, err := splitPartDev(tc.dev)
		if tc.err != (err != nil) {
			t.Fatalf("%s: err=%v, want err=%v", tc.dev, err, tc.err)
		}
		if !tc.err && (base != tc.base || num != tc.num) {
			t.Fatalf("%s: got (%s,%d), want (%s,%d)", tc.dev, base, num, tc.base, tc.num)
		}
	}
}

func TestStatusIsNormal(t *testing.T) {
	normal := []byte{0x07, 0, 0, 0, 0, 0, 0, 0}
	unbootable := []byte{0x07, 0, 0, 0, 0xFF, 0, 0, 0}
	short := []byte{0x07, 0, 0, 0, 0} // the JP6 incident: wrong-sized var
	if !statusIsNormal(normal) {
		t.Fatal("normal not recognized")
	}
	if statusIsNormal(unbootable) {
		t.Fatal("unbootable considered normal")
	}
	if statusIsNormal(short) {
		t.Fatal("wrong-size considered normal")
	}
}

func TestPrepareTargetMissingVar(t *testing.T) {
	c := testController(t)
	if err := c.PrepareTarget(connector.SlotB); err != nil {
		t.Fatalf("missing var should be tolerated: %v", err)
	}
}

func TestPrepareTargetAlreadyNormal(t *testing.T) {
	c := testController(t)
	path := writeSlotVar(t, c, connector.SlotB, []byte{0x07, 0, 0, 0, 0, 0, 0, 0})
	if err := c.PrepareTarget(connector.SlotB); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(path)
	if !statusIsNormal(raw) {
		t.Fatalf("var changed unexpectedly: % x", raw)
	}
}

func TestPrepareTargetResetsUnbootable(t *testing.T) {
	c := testController(t)
	path := writeSlotVar(t, c, connector.SlotB, []byte{0x07, 0, 0, 0, 0xFF, 0, 0, 0})
	if err := c.PrepareTarget(connector.SlotB); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !statusIsNormal(raw) {
		t.Fatalf("var not reset: % x", raw)
	}
}

func TestPrepareTargetFixesWrongSize(t *testing.T) {
	c := testController(t)
	path := writeSlotVar(t, c, connector.SlotA, []byte{0x07, 0, 0, 0, 0})
	if err := c.PrepareTarget(connector.SlotA); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(path)
	if !statusIsNormal(raw) {
		t.Fatalf("wrong-size var not fixed: % x", raw)
	}
}

func TestMarkGood(t *testing.T) {
	c := testController(t)
	c.Nvbootctrl = fakeNvbootctrl(t, "0\n") // running slot A

	// inactive slot B left unbootable by a past rollback
	pathB := writeSlotVar(t, c, connector.SlotB, []byte{0x07, 0, 0, 0, 0xFF, 0, 0, 0})

	// stale double-boot bookkeeping
	if err := os.MkdirAll(c.stateDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(c.bootAttemptedPath(), []byte("1"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := c.MarkGood(); err != nil {
		t.Fatal(err)
	}

	raw, _ := os.ReadFile(pathB)
	if !statusIsNormal(raw) {
		t.Fatalf("inactive slot not reset: % x", raw)
	}
	if _, err := os.Stat(c.bootAttemptedPath()); !os.IsNotExist(err) {
		t.Fatal("boot_attempted not cleared")
	}
}

func TestMarkGoodNoBookkeeping(t *testing.T) {
	c := testController(t)
	c.Nvbootctrl = fakeNvbootctrl(t, "1\n") // running slot B
	// no vars, no boot_attempted: must succeed as a no-op
	if err := c.MarkGood(); err != nil {
		t.Fatal(err)
	}
}
