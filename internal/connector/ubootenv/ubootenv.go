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

// GPT partition labels for the two rootfs slots. The hand-authored RPi
// A/B wks (meta-edgeos) labels its rootfs partitions exactly these, so
// slot→device resolution is a stable partlabel lookup — no partition-number
// arithmetic, no dependency on the current slot (unlike tegrauefi).
const (
	partlabelA = "rootfsA"
	partlabelB = "rootfsB"
)

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
	rootDeviceFn func() (string, error) // block device mounted at /
}

func New() *Controller {
	return &Controller{
		env:          fwEnv{printenv: "fw_printenv", setenv: "fw_setenv"},
		rootDeviceFn: currentRootDevice,
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

// --- slot ↔ partition resolution ---

func rootfsPartlabel(s connector.Slot) string {
	if s == connector.SlotA {
		return partlabelA
	}
	return partlabelB
}

// PartitionFor resolves a slot's rootfs block device by GPT partlabel.
// Unlike tegrauefi this needs no current-slot context or arithmetic: the
// wks labels the two slots rootfsA/rootfsB and they never move.
//
//  1. /dev/disk/by-partlabel/rootfs{A,B} (udev symlink — the normal path)
//  2. lsblk -rno PATH,PARTLABEL scan (early boot before the symlink exists)
func (c *Controller) PartitionFor(s connector.Slot) (string, error) {
	label := rootfsPartlabel(s)

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

// CurrentSlot returns the slot actually running, derived from the block
// device mounted at / matched against the two rootfs partitions. This is
// deliberately ground-truth (what booted) rather than reading
// wendyos_boot_slot (what we *asked* to boot): after a failed trial U-Boot
// falls back to the other slot without rewriting the env, so the running
// rootfs is the only reliable source. The engine's fallback detection
// (running slot != target slot) depends on this being real.
func (c *Controller) CurrentSlot() (connector.Slot, error) {
	root, err := c.rootDeviceFn()
	if err != nil {
		return 0, fmt.Errorf("current slot: %w", err)
	}
	root, _ = filepath.EvalSymlinks(root) // canonicalize; ignore failure

	for _, s := range []connector.Slot{connector.SlotA, connector.SlotB} {
		dev, err := c.PartitionFor(s)
		if err != nil {
			continue
		}
		if cdev, err := filepath.EvalSymlinks(dev); err == nil {
			dev = cdev
		}
		if dev == root {
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
