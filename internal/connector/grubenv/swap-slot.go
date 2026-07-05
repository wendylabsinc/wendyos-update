package grubenv

// The slot-flip half of the GRUB connector (boot-health and platform-update
// verification live in verify.go). All A/B state lives in the grubenv on the
// ESP (grub-editenv); this connector keeps no files of its own. See grubenv.go
// for the env-var contract and the GRUB trial-boot model.

import (
	"fmt"
	"log/slog"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// PrepareTarget clears any stale trial flag on the slot before a fresh update
// is armed. A previous cycle aborted between write and swap (power cut, failed
// install), or a trial that GRUB attempted but userspace never confirmed, can
// leave "<S>_TRY=1" lingering; that would make grub.cfg treat the slot as
// ineligible ("<S>_OK=1 && <S>_TRY=0" fails) and skip it. Resetting TRY to 0
// restores eligibility. The actual arming happens in SwapSlot.
//
// Only the trial flag is touched — OK is not asserted here because the slot's
// content is not yet known-good (it is about to be written); SwapSlot sets OK
// once the freshly written slot is the swap target.
func (c *Controller) PrepareTarget(s connector.Slot) error {
	if err := c.env.set(map[string]string{tryKey(s): "0"}); err != nil {
		return fmt.Errorf("prepare slot %s: %w", s, err)
	}
	return nil
}

// SwapSlot makes slot s the next-boot slot by re-pointing the grubenv.
//
//   - install (stagePlatformUpdate=true): s is the freshly written inactive
//     slot. Arm a one-shot trial — mark s good ("<S>_OK=1"), clear its trial
//     flag ("<S>_TRY=0"), and put it at the head of ORDER — all in one atomic
//     env write. On the next boot grub.cfg sets "<S>_TRY=1" and boots s; if s
//     reaches a healthy userspace it is confirmed by MarkGood, otherwise the
//     lingering TRY=1 makes the following boot fall back to the other (still
//     OK, TRY=0) slot. The rootfs is not inspected: there is no in-payload
//     bootloader update on this path (the GRUB binary is staged by a first-boot
//     service, not an OTA).
//   - rollback (stagePlatformUpdate=false): a permanent re-point to a
//     known-good slot. Same env write (ORDER head = s, s_OK=1, s_TRY=0): s is
//     an already-good slot, so putting it at the ORDER head makes it the
//     default. GRUB's one-shot TRY still applies on the immediate boot, but the
//     "no eligible slot → clear stale TRY and boot the ORDER head" branch of
//     grub.cfg guarantees the re-point survives even an unconfirmed reboot.
//
// Both cases must first pass assertEnvWritable: if the ESP is not mounted,
// grub-editenv would write a shadow grubenv on the rootfs that GRUB never reads
// and the slot change would silently no-op.
func (c *Controller) SwapSlot(s connector.Slot, stagePlatformUpdate bool) error {
	if err := c.assertEnvWritable(); err != nil {
		return fmt.Errorf("swap to slot %s: %w", s, err)
	}

	if stagePlatformUpdate {
		slog.Info("swap: arming trial boot for slot", "slot", s.String())
	} else {
		slog.Info("swap: re-pointing boot slot (rollback)", "slot", s.String())
	}

	// Identical env write for both callers: GRUB's trial mechanism is uniform
	// (grub.cfg sets TRY at boot regardless), so "install trial" vs "rollback
	// re-point" differ only in which slot is the target and whether a MarkGood
	// follows — both are expressed as ORDER head = s, s_OK=1, s_TRY=0.
	if err := c.env.set(map[string]string{
		envOrder:  orderValue(s),
		okKey(s):  "1",
		tryKey(s): "0",
	}); err != nil {
		return fmt.Errorf("swap to slot %s: %w", s, err)
	}
	return nil
}

// MarkGood finalizes a healthy, committed boot: clear the running slot's trial
// flag and re-assert its OK so it becomes the permanent default, and pin the
// ORDER head to the running slot — one atomic write. The inactive slot's OK
// flag is left untouched, so it remains a valid rollback target for the next
// cycle. Mirrors ubootenv's MarkGood (clear the trial, pin the default to the
// running slot).
func (c *Controller) MarkGood() error {
	cur, err := c.CurrentSlot()
	if err != nil {
		return fmt.Errorf("mark-good: %w", err)
	}
	if err := c.env.set(map[string]string{
		envOrder:    orderValue(cur),
		okKey(cur):  "1",
		tryKey(cur): "0",
	}); err != nil {
		return fmt.Errorf("mark-good: %w", err)
	}
	return nil
}
