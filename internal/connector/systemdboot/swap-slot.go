package systemdboot

// The slot-flip half of the systemd-boot connector (boot-health lives in
// verify.go). All persistent state is on the ESP: the loader entry file names
// (boot counter) and the kernel/initrd the entries point at. See systemdboot.go
// for the boot model and entries.go for the counter semantics.

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// SwapSlot makes slot s the next-boot slot.
//
//   - install (stagePlatformUpdate=true): s is the freshly written INACTIVE
//     slot. Stage its kernel/initrd from the new rootfs onto the ESP (systemd-boot
//     boots the kernel from the ESP, so the ESP copy MUST be refreshed to the new
//     slot's kernel), then ARM a trial — reset its entry counter to `+N` and make
//     it LoaderEntryDefault. systemd-boot decrements the counter each attempt and
//     falls back to the other, counter-less slot when the budget runs out.
//   - rollback (stagePlatformUpdate=false): a pure re-point. Drop s's counter so
//     it is permanent (not a trial) and set it default. Never mount, never stage:
//     the target may be the running slot or an old slot whose rootfs is irrelevant.
func (c *Controller) SwapSlot(s connector.Slot, stagePlatformUpdate bool) error {
	if err := c.espGuard(); err != nil {
		return fmt.Errorf("swap to slot %s: %w", s, err)
	}
	letter := slotLetter(s)

	if !stagePlatformUpdate {
		// Rollback: re-point to a known-good slot, permanently.
		slog.Info("swap: re-pointing boot slot (rollback)", "slot", s.String())
		e, err := c.findEntry(letter)
		if err != nil {
			return fmt.Errorf("swap to slot %s: %w", s, err)
		}
		if e.hasCounter() {
			if err := c.renameEntry(e, letter, noCounter, 0); err != nil {
				return fmt.Errorf("swap to slot %s: %w", s, err)
			}
		}
		if err := c.setDefault(s); err != nil {
			return fmt.Errorf("swap to slot %s: %w", s, err)
		}
		syncFS()
		return nil
	}

	// Install: stage the new slot's kernel onto the ESP, then arm a trial.
	slog.Info("swap: staging kernel and arming trial boot for slot", "slot", s.String())
	if err := c.stageKernel(s); err != nil {
		return fmt.Errorf("swap to slot %s: %w", s, err)
	}
	e, err := c.findEntry(letter)
	if err != nil {
		return fmt.Errorf("swap to slot %s: %w", s, err)
	}
	if err := c.renameEntry(e, letter, defaultTries, 0); err != nil {
		return fmt.Errorf("swap to slot %s: arm trial: %w", s, err)
	}
	if err := c.setDefault(s); err != nil {
		return fmt.Errorf("swap to slot %s: %w", s, err)
	}
	syncFS()
	return nil
}

// stageKernel mounts slot s's freshly written rootfs read-only and copies its
// kernel (and initrd, if present) onto the ESP under `/{a,b}/`, matching the
// `linux /a/Image` / `initrd /a/initrd` paths in the loader entry. This keeps the
// ESP kernel — which is what systemd-boot actually boots — in sync with the slot
// the OTA just wrote. Mirrors tegrauefi mounting the target rootfs to stage its
// capsule.
//
// RISK (documented, hardware-unverified): the kernel/initrd source paths inside
// the rootfs (KernelSrcRel/InitrdSrcRel) and the initrd's presence/name are
// image-specific; a missing kernel is a hard error (the slot would be
// unbootable) while a missing initrd is tolerated with a warning.
func (c *Controller) stageKernel(s connector.Slot) error {
	dev, err := c.PartitionFor(s)
	if err != nil {
		return err
	}
	mountDir, unmount, err := c.mountFn(dev)
	if err != nil {
		return fmt.Errorf("mount %s: %w", dev, err)
	}
	defer unmount()

	letter := slotLetter(s)
	dstDir := filepath.Join(c.ESPDir, letter)
	if err := os.MkdirAll(dstDir, 0o755); err != nil {
		return fmt.Errorf("stage kernel: %w", err)
	}

	kSrc := filepath.Join(mountDir, c.KernelSrcRel)
	if err := copyFileSync(kSrc, filepath.Join(dstDir, "Image")); err != nil {
		return fmt.Errorf("stage kernel from %s: %w", kSrc, err)
	}

	iSrc := filepath.Join(mountDir, c.InitrdSrcRel)
	if _, err := os.Stat(iSrc); err == nil {
		if err := copyFileSync(iSrc, filepath.Join(dstDir, "initrd")); err != nil {
			return fmt.Errorf("stage initrd from %s: %w", iSrc, err)
		}
	} else {
		slog.Warn("swap: no initrd in target slot rootfs; ESP entry must not reference one",
			"slot", s.String(), "path", iSrc)
	}
	return nil
}
