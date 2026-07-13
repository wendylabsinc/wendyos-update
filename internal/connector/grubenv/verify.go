package grubenv

// Boot-health and platform-update verification (mirrors ubootenv/verify.go).
// GRUB's verdict lives entirely in the trial-boot env: a still-armed trial
// running the wrong slot means the bootcount logic already fell back.

import (
	"fmt"
	"log/slog"
)

// BootIsCompromised reports whether GRUB fell back during an armed trial.
// Signal: a trial is still armed (upgrade_available=1) yet the slot we are
// running is not the slot we asked GRUB to boot — i.e. the trial did not commit
// and the GRUB config switched us back. (Once a trial commits, MarkGood clears
// upgrade_available, so a committed system never reads as compromised.)
//
// The engine also independently checks running-slot != target-slot via
// CurrentSlot; this is the connector-level corroboration the interface asks for.
func (c *Controller) BootIsCompromised() (bool, error) {
	armed, err := c.env.get(envUpgradeAvailable)
	if err != nil {
		return false, fmt.Errorf("boot health: %w", err)
	}
	if armed != "1" {
		return false, nil // no trial in flight
	}

	intended, err := c.env.get(envBootSlot)
	if err != nil {
		return false, fmt.Errorf("boot health: %w", err)
	}
	cur, err := c.CurrentSlot()
	if err != nil {
		// Can't prove a fallback; don't cry wolf. The engine's own
		// running-vs-target check still guards the commit.
		return false, nil
	}
	if intended != "" && intended != slotEnvValue(cur) {
		slog.Warn("boot health: trial armed but running a different slot than requested — GRUB fell back",
			"requested", intended, "running", cur.String())
		return true, nil
	}
	return false, nil
}

// VerifyPlatformUpdate is a no-op in v1: x86 has no in-payload bootloader update
// path (UEFI firmware is updated through fwupd / UEFI capsule independently).
// Cheap by contract.
func (c *Controller) VerifyPlatformUpdate(blUpdate bool) error {
	if blUpdate {
		slog.Info("platform verify: bootloader_update declared, but the grubenv connector has no platform-update path in v1; skipping")
	}
	return nil
}

// AbortPlatformUpdate is a no-op in v1: nothing is ever staged outside the env,
// and the trial flag is cleared by the rollback SwapSlot itself.
func (c *Controller) AbortPlatformUpdate() error { return nil }
