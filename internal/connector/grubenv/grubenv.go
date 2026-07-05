// Package grubenv implements connector.Connector for boards that select
// the A/B rootfs slot from a GRUB2 environment block (grubenv) on the ESP.
// It is the third connector after tegrauefi and ubootenv, and the GRUB
// realization of A/B on NVIDIA Jetson Orin — where NVIDIA's own firmware
// rootfs redundancy cannot be armed from the OS (efivar writes EINVAL on
// Orin), a GRUB2 UEFI application (grubaa64.efi) enrolled first in BootOrder
// owns the slot selection instead.
//
// Where tegrauefi drives nvbootctrl + efivars + UEFI capsules, and ubootenv
// drives libubootenv's trial-boot counters, this connector drives GRUB's
// standard A/B pattern (RAUC's contrib/grub.conf model) through grub-editenv:
//
//   - grub.cfg does `load_env` from the grubenv, then picks the first slot in
//     ORDER whose "<S>_OK=1 && <S>_TRY=0"; it sets that slot's "<S>_TRY=1",
//     `save_env`, and boots it. That one-shot TRY write is the fallback
//     mechanism: a boot that dies before userspace confirms leaves TRY=1, so
//     the next boot skips that slot and falls to the other OK slot. If no slot
//     is eligible, grub.cfg clears the stale TRY flags and boots the ORDER
//     head (brick-avoidance).
//   - committing a boot (MarkGood) clears the running slot's TRY and re-asserts
//     its OK, making it the permanent default.
//
// The env-var contract (grub.cfg must honor exactly these names):
//
//	ORDER   "A B" | "B A"   — slot preference order (head is the intended slot)
//	A_OK    "0" | "1"       — slot A is a known-good boot target
//	A_TRY   "0" | "1"       — a one-shot trial of slot A is in flight
//	B_OK    "0" | "1"       — slot B is a known-good boot target
//	B_TRY   "0" | "1"       — a one-shot trial of slot B is in flight
//
// Slot ↔ partition resolution reuses the NVIDIA rootfs partition labels
// (APP = slot 0, APP_b = slot 1), and CurrentSlot is derived from the running
// root device (findmnt / → partlabel), not from the grubenv — the ground truth
// for "what booted" is the mounted rootfs, since a GRUB fallback runs a
// different slot than ORDER without rewriting the env (mirrors ubootenv and
// tegrauefi, whose CurrentSlot is likewise the running slot).
//
// Platform (bootloader/firmware) updates are out of scope on this path:
// VerifyPlatformUpdate and AbortPlatformUpdate are no-ops, and install never
// inspects the payload for a bootloader marker. The GRUB binary itself is
// re-staged onto the ESP by a first-boot service in the OS image, not by an OTA.
package grubenv

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// DefaultEnvPath is where the OS image stages the grubenv on the ESP FAT
// (EFI/wendyos/grubenv, beside grubaa64.efi). Overridable via the Controller
// field for tests and non-standard layouts.
const DefaultEnvPath = "/boot/efi/EFI/wendyos/grubenv"

// grubEditenvBin is the libgrub tool that reads/writes a grubenv block.
const grubEditenvBin = "grub-editenv"

// NVIDIA rootfs partition labels: APP = slot 0 (A), APP_b = slot 1 (B).
// Identical to tegrauefi's mapping — the GRUB path reuses the same disk layout.
const (
	partlabelA = "APP"
	partlabelB = "APP_b"
)

// grubenv variable names (the grub.cfg A/B contract; see the package doc).
const (
	envOrder = "ORDER"
	suffixOK = "_OK"  // "<S>_OK"
	suffixTr = "_TRY" // "<S>_TRY"
)

func init() {
	connector.Register("grubenv", connector.Factory{
		New:    func() connector.Connector { return New() },
		Detect: detect,
	})
}

// detect: grub-editenv present AND a grubenv exists at the default ESP path.
// On a Tegra board tegrauefi also matches, so images pin connector=grubenv in
// /etc/wendyos-update/config.json — detection is only a secondary safety net.
func detect() bool {
	if _, err := exec.LookPath(grubEditenvBin); err != nil {
		return false
	}
	_, err := os.Stat(DefaultEnvPath)
	return err == nil
}

// envStore is the grubenv access seam. The real implementation shells out to
// grub-editenv; tests substitute an in-memory store. set writes all vars in a
// single grub-editenv invocation, which rewrites the whole env block, so a
// power cut cannot leave a half-armed trial (slot flipped but flag unset).
type envStore interface {
	list() (map[string]string, error)
	set(vars map[string]string) error
}

// Controller implements connector.Connector via grub-editenv + the running
// root device. Every platform seam (env access, running-root resolution, the
// mountpoint probe, device path prefix) is a field so tests can fake the board.
type Controller struct {
	GrubEditenv string // binary name/path (injectable for tests)
	EnvPath     string // grubenv file on the ESP (injectable for tests)
	RootDir     string // prefix for /dev lookups (tests); "" in production

	env          envStore
	rootDeviceFn func() (string, error)          // block device mounted at /
	mountpointFn func(path string) (bool, error) // is path a filesystem mountpoint
}

func New() *Controller {
	c := &Controller{
		GrubEditenv:  grubEditenvBin,
		EnvPath:      DefaultEnvPath,
		RootDir:      "",
		rootDeviceFn: currentRootDevice,
		mountpointFn: isMountpoint,
	}
	c.env = grubEnv{bin: c.GrubEditenv, path: c.EnvPath}
	return c
}

var _ connector.Connector = (*Controller)(nil)

func (c *Controller) Name() string { return "grubenv" }

// --- grub-editenv-backed envStore ---

type grubEnv struct {
	bin  string
	path string
}

// list reads every variable via `grub-editenv <path> list`, which prints one
// "KEY=VALUE" per line. A missing/empty env reads as an empty map (the
// fail-safe direction: absent OK/TRY flags are treated as "not good / no
// trial" by the callers).
func (g grubEnv) list() (map[string]string, error) {
	out, err := exec.Command(g.bin, g.path, "list").Output()
	if err != nil {
		return nil, fmt.Errorf("grub-editenv list: %w", err)
	}
	m := map[string]string{}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		m[strings.TrimSpace(k)] = strings.TrimSpace(v)
	}
	return m, nil
}

// set writes variables in one `grub-editenv <path> set K=V ...` call. A single
// invocation rewrites the entire env block, so the slot + flags + order land
// together. Values must not contain spaces (all ours are "0"/"1" or "A B").
//
// A global sync follows: callers arm a trial and reboot almost immediately, and
// the grubenv is a file on the ESP FAT; the sync gets the env write (and the
// freshly written inactive rootfs) onto disk before the reboot.
func (g grubEnv) set(vars map[string]string) error {
	args := []string{g.path, "set"}
	for k, v := range vars {
		args = append(args, k+"="+v)
	}
	if out, err := exec.Command(g.bin, args...).CombinedOutput(); err != nil {
		return fmt.Errorf("grub-editenv set: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	syscall.Sync()
	return nil
}

// get reads a single variable (empty string if unset). Backed by list, since
// grub-editenv has no single-key read.
func (c *Controller) get(name string) (string, error) {
	m, err := c.env.list()
	if err != nil {
		return "", err
	}
	return m[name], nil
}

// --- writable-env guard (the shadow-file trap, ported from ubootenv) ---

// assertEnvWritable refuses a write that would silently no-op. The grubenv
// lives on the ESP FAT (EFI/wendyos/grubenv); the OS mounts the ESP at
// /boot/efi. If that mount is missing, grub-editenv happily writes a *copy* of
// the grubenv into the empty directory tree on the rootfs and exits 0 — but
// GRUB reads the real ESP FAT, so the slot change never takes effect and the
// device just reboots the current slot (a silent no-op OTA). This is the exact
// lesson ubootenv learned with fw_setenv and /boot `nofail` (WDY-1768).
//
// So: walk up from the grubenv's directory; if a real sub-mount (the ESP) is
// found above it, the write is safe. If we can cleanly determine that NO
// sub-mount exists between the grubenv and the filesystem root — i.e. the
// grubenv would land on the rootfs — refuse. Fail OPEN when nothing can be
// determined (only stat errors), matching ubootenv: this closes the specific
// shadow-file trap without blocking on an environment we cannot read.
func (c *Controller) assertEnvWritable() error {
	dir := filepath.Dir(c.EnvPath)
	sawCleanFalse := false
	for {
		mp, err := c.mountpointFn(filepath.Join(c.RootDir, dir))
		if err == nil {
			if mp {
				return nil // a real mount above the grubenv (the ESP) — safe
			}
			sawCleanFalse = true
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break // reached the filesystem root without hitting a sub-mount
		}
		dir = parent
	}
	if sawCleanFalse {
		return fmt.Errorf("grubenv %s is not on a mounted ESP (is %s mounted?): "+
			"refusing — grub-editenv would write a copy GRUB never reads",
			c.EnvPath, filepath.Dir(c.EnvPath))
	}
	return nil // only stat errors seen: cannot determine, don't block
}

// isMountpoint reports whether path is a filesystem mountpoint, by the standard
// test: its st_dev differs from its parent's. Linux/Unix only (matches the
// connector's syscall use); the seam lets tests fake it deterministically.
func isMountpoint(path string) (bool, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return false, err
	}
	parent, err := os.Stat(filepath.Dir(path))
	if err != nil {
		return false, err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	pst, ok2 := parent.Sys().(*syscall.Stat_t)
	if !ok || !ok2 {
		return false, fmt.Errorf("stat %s: unexpected FileInfo.Sys type", path)
	}
	return st.Dev != pst.Dev, nil
}

// --- slot ↔ partition resolution (reuses tegrauefi's APP/APP_b labels) ---

func partlabelFor(s connector.Slot) string {
	if s == connector.SlotA {
		return partlabelA
	}
	return partlabelB
}

// PartitionFor resolves a slot's rootfs block device by its NVIDIA partition
// label (APP / APP_b), mirroring tegrauefi:
//
//  1. /dev/disk/by-partlabel/APP | APP_b (standard on the Orin NVMe layout)
//  2. lsblk -rno PATH,PARTLABEL scan (fallback when the symlink is absent)
func (c *Controller) PartitionFor(s connector.Slot) (string, error) {
	label := partlabelFor(s)

	link := c.RootDir + "/dev/disk/by-partlabel/" + label
	if dev, err := filepath.EvalSymlinks(link); err == nil {
		return dev, nil
	}

	if out, err := exec.Command("lsblk", "-rno", "PATH,PARTLABEL").Output(); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			fields := strings.Fields(line)
			if len(fields) == 2 && fields[1] == label {
				return fields[0], nil
			}
		}
	}

	return "", fmt.Errorf("partition for slot %s: no partition labelled %q", s, label)
}

// CurrentSlot returns the slot actually running, derived from the block device
// mounted at / matched against each slot's resolved partition. This is
// deliberately ground truth (what booted) rather than the grubenv's ORDER (what
// we asked to boot): after a failed trial GRUB falls back to the other slot
// without rewriting the env, so the running rootfs is the only reliable source.
// The engine's fallback detection (running slot != target slot) depends on this
// being real — mirrors ubootenv and tegrauefi.
func (c *Controller) CurrentSlot() (connector.Slot, error) {
	root, err := c.rootDeviceFn()
	if err != nil {
		return 0, fmt.Errorf("current slot: %w", err)
	}
	root = canon(root)
	for _, s := range []connector.Slot{connector.SlotA, connector.SlotB} {
		dev, err := c.PartitionFor(s)
		if err != nil {
			continue
		}
		if canon(dev) == root {
			return s, nil
		}
	}
	return 0, fmt.Errorf("current slot: running root %q matches neither rootfs slot (%s/%s)",
		root, partlabelA, partlabelB)
}

// currentRootDevice returns the block device mounted at / (findmnt is in
// util-linux, present on every WendyOS image).
func currentRootDevice() (string, error) {
	out, err := exec.Command("findmnt", "-no", "SOURCE", "/").Output()
	if err != nil {
		return "", fmt.Errorf("findmnt /: %w", err)
	}
	dev := strings.TrimSpace(string(out))
	if dev == "" {
		return "", fmt.Errorf("findmnt /: empty source")
	}
	return dev, nil
}

// canon canonicalizes a device path via EvalSymlinks, returning the input
// unchanged on failure (e.g. the path is not a real node, as in unit tests).
func canon(dev string) string {
	if c, err := filepath.EvalSymlinks(dev); err == nil {
		return c
	}
	return dev
}

// --- grubenv key/value helpers ---

func okKey(s connector.Slot) string  { return s.String() + suffixOK }
func tryKey(s connector.Slot) string { return s.String() + suffixTr }

// orderValue renders the ORDER string with s as the head (the intended slot),
// e.g. slot B -> "B A".
func orderValue(s connector.Slot) string {
	return s.String() + " " + s.Other().String()
}

// orderHeadSlot parses the head (first token) of an ORDER string into a Slot.
// ok=false when the ORDER is empty or unrecognized.
func orderHeadSlot(order string) (connector.Slot, bool) {
	fields := strings.Fields(order)
	if len(fields) == 0 {
		return 0, false
	}
	switch fields[0] {
	case connector.SlotA.String():
		return connector.SlotA, true
	case connector.SlotB.String():
		return connector.SlotB, true
	default:
		return 0, false
	}
}
