package grubenv

// The slot-flip half of the GRUB connector (boot-health and platform-update
// verification live in verify.go). All state lives in the GRUB environment block
// (grub-editenv); this connector keeps no files of its own. See grubenv.go for
// the env-var contract and the trial-boot model.

import (
	"fmt"
	"log/slog"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// PrepareTarget clears any stale trial state before a fresh slot is armed. A
// previous cycle that was aborted (power cut between write and swap, a failed
// install) could leave wendyos_upgrade_available=1 or a non-zero bootcount
// lingering; arming a new trial on top of that would mis-count the retry budget.
// This resets the baseline. The actual arming happens in SwapSlot.
//
// The freshly written slot needs no per-slot "make bootable" step (GRUB has no
// unbootable marker like Tegra's RootfsStatusSlot), so this is environment
// hygiene only — the s argument is accepted for interface symmetry.
func (c *Controller) PrepareTarget(s connector.Slot) error {
	if err := c.env.set(map[string]string{
		envUpgradeAvailable: "0",
		envBootCount:        "0",
	}); err != nil {
		return fmt.Errorf("prepare slot %s: %w", s, err)
	}
	return nil
}

// SwapSlot makes slot s the next-boot slot.
//
//   - install (stagePlatformUpdate=true): s is the freshly written inactive
//     slot. Arm a TRIAL boot — point the GRUB config at s, set the trial flag,
//     zero the counter — all in one atomic env write. If the trial slot never
//     reaches a healthy userspace and commits, the GRUB config's bootcount logic
//     falls back to the old slot on its own. v1 has no in-payload bootloader
//     update, so the rootfs is not inspected (x86 firmware is a separate fwupd
//     path).
//   - rollback (stagePlatformUpdate=false): a pure re-point. Set the boot slot
//     to s and DISARM the trial (upgrade_available=0) so the next boot is
//     permanent, not a trial. Never a trial — rollback returns to a known-good
//     slot.
func (c *Controller) SwapSlot(s connector.Slot, stagePlatformUpdate bool) error {
	// Refuse if the ESP is not mounted: otherwise grub-editenv writes a shadow
	// copy GRUB never reads and the slot change silently no-ops (see
	// assertEnvWritable).
	if err := c.assertEnvWritable(); err != nil {
		return fmt.Errorf("swap to slot %s: %w", s, err)
	}

	if stagePlatformUpdate {
		slog.Info("swap: arming trial boot for slot", "slot", s.String())
		if err := c.env.set(map[string]string{
			envBootSlot:         slotEnvValue(s),
			envUpgradeAvailable: "1",
			envBootCount:        "0",
		}); err != nil {
			return fmt.Errorf("swap to slot %s: arm trial: %w", s, err)
		}
		return nil
	}

	slog.Info("swap: re-pointing boot slot (rollback)", "slot", s.String())
	if err := c.env.set(map[string]string{
		envBootSlot:         slotEnvValue(s),
		envUpgradeAvailable: "0",
		envBootCount:        "0",
	}); err != nil {
		return fmt.Errorf("swap to slot %s: re-point: %w", s, err)
	}
	return nil
}

// MarkGood finalizes a healthy, committed boot: clear the trial flag so the
// current slot becomes the permanent default, pin wendyos_boot_slot to the
// running slot, and zero the counter for the next cycle — one atomic write.
func (c *Controller) MarkGood() error {
	cur, err := c.CurrentSlot()
	if err != nil {
		return fmt.Errorf("mark-good: %w", err)
	}
	if err := c.env.set(map[string]string{
		envBootSlot:         slotEnvValue(cur),
		envUpgradeAvailable: "0",
		envBootCount:        "0",
	}); err != nil {
		return fmt.Errorf("mark-good: %w", err)
	}
	return nil
}
