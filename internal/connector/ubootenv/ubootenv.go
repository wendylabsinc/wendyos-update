// Package ubootenv implements connector.Connector for U-Boot boards
// (Raspberry Pi 3/4/5 and any board whose A/B selection lives in the
// U-Boot environment). It is the second connector after tegrauefi and the
// realization of plan Phase 7 (meta-edgeos/docs/plans/wendyos-update-rpi.md).
//
// Where tegrauefi leans on NVIDIA's boot-control framework (nvbootctrl +
// efivars + UEFI capsules), this connector drives the much simpler U-Boot
// "trial boot" pattern through libubootenv (fw_printenv/fw_setenv):
//
//   - the boot script picks the rootfs slot from `wendyos_boot_slot`;
//   - when `wendyos_upgrade_available=1` the boot is a TRIAL: U-Boot's
//     native bootcount/bootlimit/altbootcmd machinery falls back to the
//     other slot if the trial slot fails to reach a healthy userspace;
//   - committing clears `wendyos_upgrade_available` so the slot becomes
//     the permanent default.
//
// This mirrors meta-mender-raspberrypi's proven U-Boot integration
// (`mender_boot_part`/`upgrade_available`/`bootcount`) under our own
// variable names — see the env-var contract in the plan doc. The U-Boot
// boot script and fw_env.config live in meta-edgeos; this connector only
// reads and writes the environment.
//
// The env-var contract (the boot script must honor the same names):
//
//	wendyos_boot_slot          "0" (A) | "1" (B)  — slot the boot script selects
//	wendyos_upgrade_available  "0" | "1"          — a trial boot is armed
//	bootcount                  integer            — U-Boot's native counter
//
// Platform updates (rpi-eeprom / firmware) are out of scope in v1:
// VerifyPlatformUpdate and AbortPlatformUpdate are no-ops, and install
// never inspects the payload for a bootloader marker.
package ubootenv

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// Environment variable names (our names; documented contract). The boot
// script in meta-edgeos selects the slot and arms the trial boot off
// exactly these.
const (
	envBootSlot         = "wendyos_boot_slot"
	envUpgradeAvailable = "wendyos_upgrade_available"
	envBootCount        = "bootcount" // U-Boot's native counter
)

// Slot labels for the two rootfs slots. The hand-authored RPi A/B wks
// (meta-edgeos) labels its rootfs partitions exactly these, so slot→device
// resolution is a stable label lookup — no partition-number arithmetic, no
// dependency on the current slot (unlike tegrauefi).
//
// On the GPT boards (rpi4/rpi5) these are GPT PARTLABELs. On an MBR table
// (rpi3, whose BCM2837 bootrom can only boot MBR) there are no partlabels, so
// the same names are carried as the ext4 FILESYSTEM label (`wic --label`).
// effectiveLabel() prefers the partlabel and falls back to the fs label, so
// GPT resolution is unchanged and MBR resolves through the fallback.
const (
	partlabelA = "rootfsA"
	partlabelB = "rootfsB"
)

// On an MBR table (rpi3) there are no GPT partlabels, and an OTA rootfs write
// overwrites the target filesystem — including its ext4 label — so NEITHER the
// partlabel nor the fs label is a slot identity that survives an update. The one
// thing that does survive is the PARTITION NUMBER (the MBR partition table is
// never rewritten by an OTA). Resolve A/B by number there, matching the
// authoritative mapping in the boot script
// (recipes-bsp/rpi-u-boot-scr/files/boot-ab.cmd.in) and the image layout
// (files/wic/rpi-wendy-ab-mbr.wks): slot 0 = rootfsA = partition 2,
// slot 1 = rootfsB = partition 3, on the boot disk.
const (
	mbrRootfsPartA = 2
	mbrRootfsPartB = 3
)

// mbrPartForSlot maps a slot to its MBR rootfs partition number (see above).
func mbrPartForSlot(s connector.Slot) int {
	if s == connector.SlotB {
		return mbrRootfsPartB
	}
	return mbrRootfsPartA
}

func init() {
	connector.Register("ubootenv", connector.Factory{
		New:    func() connector.Connector { return New() },
		Detect: detect,
	})
}

// detect: fw_printenv present AND our env layout seeded (wendyos_boot_slot
// is defined). On a Tegra board fw_printenv is absent, so this never
// collides with tegrauefi. RPi images additionally pin the connector
// explicitly via /etc/wendyos-update/config.json, so detection is only a
// secondary safety net.
func detect() bool {
	if _, err := exec.LookPath("fw_printenv"); err != nil {
		return false
	}
	v, err := New().env.get(envBootSlot)
	return err == nil && v != ""
}

// envStore is the U-Boot environment access seam. The real implementation
// shells out to libubootenv; tests substitute an in-memory store. set is a
// single atomic batch (libubootenv writes the whole script transactionally),
// which matters when arming a trial: slot + flag + counter must land together.
type envStore interface {
	get(name string) (string, error)
	set(vars map[string]string) error
}

// Controller implements connector.Connector via libubootenv. Every
// platform seam (env access, running-root resolution, device path prefix)
// is a field so tests can fake the board completely.
type Controller struct {
	RootDir string // prefix for /dev lookups (tests); "" in production

	env          envStore
	rootDeviceFn func() (string, error)     // block device mounted at /
	listPartsFn  func() ([]partInfo, error) // block partitions (lsblk)
}

func New() *Controller {
	return &Controller{
		env:          fwEnv{printenv: "fw_printenv", setenv: "fw_setenv"},
		rootDeviceFn: currentRootDevice,
		listPartsFn:  lsblkParts,
	}
}

var _ connector.Connector = (*Controller)(nil)

func (c *Controller) Name() string { return "ubootenv" }

// --- libubootenv-backed envStore ---

type fwEnv struct {
	printenv string
	setenv   string
}

// get reads one variable. fw_printenv exits non-zero when the variable is
// unset; we treat "unset" as the empty string (a missing trial flag means
// "no trial", a missing slot means "unknown" — both safe defaults the
// callers already handle). A genuinely broken env therefore also reads as
// empty, which is the fail-safe direction for every caller here.
func (f fwEnv) get(name string) (string, error) {
	out, err := exec.Command(f.printenv, "-n", name).Output()
	if err != nil {
		return "", nil
	}
	return strings.TrimSpace(string(out)), nil
}

// set writes variables atomically. libubootenv's `fw_setenv -s <file>` applies
// the whole script in a single redundant-env write, so a power cut cannot leave
// a half-armed trial (slot flipped but flag unset, or vice versa).
//
// Two libubootenv specifics, both learned the hard way bringing up RPi OTA:
//   - the script MUST use "key=value"; libubootenv silently IGNORES any line
//     without '=' (see `fw_setenv --help`). The earlier "key value" form made
//     every write a no-op (exit 0, nothing changed) so trials were never armed.
//   - `-s` opens a real file; it does NOT treat "-" as stdin. So write a temp
//     file and pass its path, rather than piping the script to stdin.
func (f fwEnv) set(vars map[string]string) error {
	tmp, err := os.CreateTemp("", "wendyos-fwenv-*.txt")
	if err != nil {
		return fmt.Errorf("fw_setenv: create script: %w", err)
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(envScript(vars)); err != nil {
		tmp.Close()
		return fmt.Errorf("fw_setenv: write script: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("fw_setenv: close script: %w", err)
	}
	if out, err := exec.Command(f.setenv, "-s", tmp.Name()).CombinedOutput(); err != nil {
		return fmt.Errorf("fw_setenv: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	// Flush before returning: callers arm a trial then reboot almost
	// immediately, and on RPi the env is a file on the FAT (CONFIG_ENV_IS_IN_FAT).
	// A global sync gets the env write (and the freshly written inactive rootfs)
	// onto disk before the reboot. Harmless on Tegra.
	syscall.Sync()
	return nil
}

// envScript renders vars as a libubootenv `-s` script — one "key=value" per
// line. The '=' is REQUIRED: libubootenv silently ignores lines without it.
func envScript(vars map[string]string) string {
	var b strings.Builder
	for k, v := range vars {
		fmt.Fprintf(&b, "%s=%s\n", k, v)
	}
	return b.String()
}

// fwEnvConfigPath is libubootenv's config (read by fw_setenv); it names where
// the U-Boot environment lives. We parse it only to sanity-check the arm.
const fwEnvConfigPath = "/etc/fw_env.config"

// assertEnvWritable guards against a silently-ineffective env write. On RPi the
// U-Boot env is a file on the FAT boot partition (fw_env.config -> /boot/uboot.env),
// and the GPT fstab mounts /boot with `nofail` (WDY-1768). If /boot fails to
// mount, fw_setenv happily writes a *copy* of uboot.env into the empty /boot
// directory on the rootfs and exits 0 — but U-Boot reads the real FAT, so a
// trial is never armed and the device just reboots the current slot (a silent
// no-op OTA, indistinguishable from success to the caller).
//
// So: if the configured env is a regular file, refuse unless its parent
// directory is a real mountpoint. Fail OPEN on anything we cannot determine
// (unreadable config, raw block-device env, unstattable path) — fw_setenv
// surfaces genuine errors itself; this only closes the specific shadow-file trap.
func (c *Controller) assertEnvWritable() error {
	data, err := os.ReadFile(filepath.Join(c.RootDir, fwEnvConfigPath))
	if err != nil {
		return nil // no/unreadable config: don't block (tests, non-RPi boards, ...)
	}
	dev := firstEnvField(string(data))
	if dev == "" || strings.HasPrefix(dev, "/dev/") {
		return nil // unparseable, or a raw block device (no mount semantics)
	}
	dir := filepath.Dir(dev)
	mp, err := isMountpoint(filepath.Join(c.RootDir, dir))
	if err != nil {
		return nil // cannot stat (e.g. /boot absent): let fw_setenv decide
	}
	if !mp {
		return fmt.Errorf("u-boot env %s is not on a mounted boot partition "+
			"(is %s mounted?): refusing — fw_setenv would write a copy the bootloader never reads", dev, dir)
	}
	return nil
}

// firstEnvField returns the first whitespace-separated token of the first
// non-blank, non-comment line of an fw_env.config (the device-or-file path).
func firstEnvField(cfg string) string {
	for _, line := range strings.Split(cfg, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		return strings.Fields(line)[0]
	}
	return ""
}

// isMountpoint reports whether path is a filesystem mountpoint, by the standard
// test: its st_dev differs from its parent's. Linux-only (matches this file's
// existing syscall use).
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

// --- slot ↔ partition resolution ---

func rootfsSlotLabel(s connector.Slot) string {
	if s == connector.SlotA {
		return partlabelA
	}
	return partlabelB
}

// partInfo is one block partition as reported by lsblk: device path, GPT
// partlabel, filesystem label, and parent whole-disk kernel name (PKNAME).
type partInfo struct {
	path      string // e.g. /dev/mmcblk0p3
	partlabel string // GPT partition name, e.g. rootfsA ("" on an MBR table)
	label     string // filesystem label, e.g. rootfsA (MBR fallback for partlabel)
	pkname    string // parent disk kernel name, e.g. mmcblk0 ("" for a disk)
}

// effectiveLabel is a partition's slot identity: the GPT partlabel when present,
// else the filesystem label. GPT boards (rpi4/rpi5) always set a partlabel, so
// they never consult the fs label and resolve exactly as before. MBR (rpi3) has
// no partlabel, so it resolves through the fs label `wic --label` wrote.
func effectiveLabel(p partInfo) string {
	if p.partlabel != "" {
		return p.partlabel
	}
	return p.label
}

// bootDiskHasPartlabel reports whether ANY partition on the given disk carries a
// GPT PARTLABEL. On GPT boards (rpi4/rpi5) every rootfs partition does, so slots
// resolve by partlabel exactly as before. On an MBR table (rpi3) none do, so we
// resolve by partition number instead (mbrRootfsPart*) — the only slot identity
// that survives an OTA that rewrites the rootfs filesystem and its fs label.
// Decided once per disk so a mixed-signal partition can never be partially
// resolved by number.
func bootDiskHasPartlabel(parts []partInfo, disk string) bool {
	for _, p := range parts {
		if p.pkname == disk && p.partlabel != "" {
			return true
		}
	}
	return false
}

// partNum extracts a partition's number from its device path given the parent
// disk kernel name: ("/dev/mmcblk0p3","mmcblk0")->3, ("/dev/sda3","sda")->3,
// ("/dev/nvme0n1p3","nvme0n1")->3. ok=false if it cannot be parsed.
func partNum(path, pkname string) (int, bool) {
	if pkname == "" {
		return 0, false
	}
	suffix := strings.TrimPrefix(strings.TrimPrefix(path, "/dev/"), pkname)
	suffix = strings.TrimPrefix(suffix, "p") // mmcblk0p3 / nvme0n1p3 (sdaN has no 'p')
	n, err := strconv.Atoi(suffix)
	if err != nil {
		return 0, false
	}
	return n, true
}

// lsblkParts lists block partitions with their partlabel, fs label and parent
// disk. -P (KEY="value") is used over -r because it is robust to empty columns
// (partitions with no partlabel, e.g. every partition on an MBR table).
func lsblkParts() ([]partInfo, error) {
	out, err := exec.Command("lsblk", "-Pno", "PATH,PARTLABEL,LABEL,PKNAME").Output()
	if err != nil {
		return nil, err
	}
	var parts []partInfo
	for _, line := range strings.Split(string(out), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		parts = append(parts, partInfo{
			path:      lsblkField(line, "PATH"),
			partlabel: lsblkField(line, "PARTLABEL"),
			label:     lsblkField(line, "LABEL"),
			pkname:    lsblkField(line, "PKNAME"),
		})
	}
	return parts, nil
}

// lsblkField extracts KEY's value from an lsblk -P line (KEY="value" ...).
func lsblkField(line, key string) string {
	pfx := key + `="`
	i := strings.Index(line, pfx)
	if i < 0 {
		return ""
	}
	i += len(pfx)
	j := strings.IndexByte(line[i:], '"')
	if j < 0 {
		return ""
	}
	return line[i : i+j]
}

// canon canonicalizes a device path via EvalSymlinks, returning the input
// unchanged on failure (e.g. the path is not a real node, as in unit tests).
func canon(dev string) string {
	if c, err := filepath.EvalSymlinks(dev); err == nil {
		return c
	}
	return dev
}

// bootDisk returns the parent whole-disk kernel name (PKNAME) of the running
// root, e.g. "mmcblk0" for /dev/mmcblk0p3. Rootfs-slot resolution is scoped to
// this disk so a SECOND flashed disk (e.g. an NVMe beside the SD, both carrying
// rootfsA/rootfsB) cannot shadow the disk we actually booted from — and so
// `install` never writes the inactive slot to the wrong disk.
func (c *Controller) bootDisk(parts []partInfo) (string, error) {
	root, err := c.rootDeviceFn()
	if err != nil {
		return "", err
	}
	root = canon(root)
	for _, p := range parts {
		if canon(p.path) == root {
			return p.pkname, nil
		}
	}
	return "", fmt.Errorf("running root %q not found among partitions", root)
}

// PartitionFor resolves a slot's rootfs block device, scoped to the disk we
// booted from (see bootDisk):
//
//   - GPT (rpi4/5): by GPT partlabel (rootfsA/rootfsB) — stable across OTA.
//   - MBR (rpi3): by partition number (rootfsA=p2, rootfsB=p3), because an OTA
//     rootfs write wipes the target's ext4 label and MBR has no partlabel, so
//     the number is the only durable identity (mbrRootfsPart* / boot-ab.cmd.in).
//
// Falls back to the /dev/disk/by-partlabel then by-label symlinks only when the
// running root is not listed by lsblk (early boot / unit tests); those symlinks
// are ambiguous across a second disk, so they are the last resort — and on MBR
// the number branch returns before reaching them (the by-label symlink is a
// factory-state-only net that would miss, correctly, post-OTA).
func (c *Controller) PartitionFor(s connector.Slot) (string, error) {
	label := rootfsSlotLabel(s)

	if parts, err := c.listPartsFn(); err == nil {
		if disk, err := c.bootDisk(parts); err == nil && disk != "" {
			if bootDiskHasPartlabel(parts, disk) {
				// GPT: resolve by partlabel. On a miss, fall through to the
				// symlink fallback below (unchanged behavior).
				for _, p := range parts {
					if effectiveLabel(p) == label && p.pkname == disk {
						return p.path, nil
					}
				}
			} else {
				// MBR: resolve by partition number, scoped to the boot disk.
				want := mbrPartForSlot(s)
				for _, p := range parts {
					if p.pkname != disk {
						continue
					}
					if n, ok := partNum(p.path, p.pkname); ok && n == want {
						return p.path, nil
					}
				}
				return "", fmt.Errorf("partition for slot %s: no partition %d on MBR boot disk %q", s, want, disk)
			}
		}
	}

	for _, base := range []string{"/dev/disk/by-partlabel/", "/dev/disk/by-label/"} {
		if dev, err := filepath.EvalSymlinks(c.RootDir + base + label); err == nil {
			return dev, nil
		}
	}

	return "", fmt.Errorf("partition for slot %s: no partition labelled %q on the boot disk", s, label)
}

// CurrentSlot returns the slot actually running, derived from the block device
// mounted at /. This is deliberately ground-truth (what booted) rather than
// reading wendyos_boot_slot (what we *asked* to boot): after a failed trial
// U-Boot falls back to the other slot without rewriting the env, so the running
// rootfs is the only reliable source. The engine's fallback detection (running
// slot != target slot) depends on this being real.
func (c *Controller) CurrentSlot() (connector.Slot, error) {
	root, err := c.rootDeviceFn()
	if err != nil {
		return 0, fmt.Errorf("current slot: %w", err)
	}
	root = canon(root)

	// Identify the running root partition by its OWN device (unambiguous even when
	// a second disk carries the same rootfsA/rootfsB). On GPT (rpi4/5) by its
	// partlabel; on MBR (rpi3) by its partition number, because the OTA rootfs
	// write wipes the just-committed slot's fs label (see bootDiskHasPartlabel /
	// mbrRootfsPart*).
	if parts, err := c.listPartsFn(); err == nil {
		for _, p := range parts {
			if canon(p.path) != root {
				continue
			}
			if bootDiskHasPartlabel(parts, p.pkname) {
				switch effectiveLabel(p) {
				case partlabelA:
					return connector.SlotA, nil
				case partlabelB:
					return connector.SlotB, nil
				}
			} else if n, ok := partNum(p.path, p.pkname); ok {
				switch n {
				case mbrRootfsPartA:
					return connector.SlotA, nil
				case mbrRootfsPartB:
					return connector.SlotB, nil
				}
			}
			break // running root found; its identity didn't resolve — fall through
		}
	}

	// Fallback (running root not listed by lsblk, e.g. unit tests): compare the
	// running root against each slot's resolved device.
	for _, s := range []connector.Slot{connector.SlotA, connector.SlotB} {
		dev, err := c.PartitionFor(s)
		if err != nil {
			continue
		}
		if canon(dev) == root {
			return s, nil
		}
	}
	return 0, fmt.Errorf("current slot: running root %q matches neither rootfs slot (%s/%s)", root, partlabelA, partlabelB)
}

// currentRootDevice returns the block device mounted at / (findmnt is in
// util-linux, present on every RPi image).
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

// slotEnvValue maps a slot to the wendyos_boot_slot string the boot script
// expects ("0"/"1", same encoding as connector.Slot's int value).
func slotEnvValue(s connector.Slot) string {
	return fmt.Sprintf("%d", int(s))
}
