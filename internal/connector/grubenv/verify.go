package grubenv

// Boot-health and platform-update verification (mirrors ubootenv/verify.go).
// Where Tegra reads RootfsStatusSlot efivars and runs the ESRT capsule cascade,
// GRUB's fallback verdict is visible in the grubenv: a boot whose running slot
// is not the ORDER head means grub.cfg skipped the intended (trial) slot and
// fell back to the other OK slot.

import (
	"fmt"
	"log/slog"
)

// BootIsCompromised reports whether GRUB fell back during an armed trial.
// Signal: the slot we are running is not the ORDER head (the slot we asked
// grub.cfg to boot). After an install the ORDER head is the freshly written
// trial slot; if that slot's boot died before userspace, grub.cfg's lingering
// "<S>_TRY=1" makes the next boot fall back to the other slot — so running a
// slot other than the ORDER head is the corroborating fallback signal.
//
// The engine also independently checks running-slot != target-slot via
// CurrentSlot; this is the connector-level corroboration the interface asks
// for. Conservative on uncertainty: an unreadable env or an unknown current
// slot returns "not compromised" rather than crying wolf (a committed system,
// where MarkGood pins the ORDER head to the running slot, always reads healthy).
func (c *Controller) BootIsCompromised() (bool, error) {
	m, err := c.env.list()
	if err != nil {
		return false, fmt.Errorf("boot health: %w", err)
	}
	head, ok := orderHeadSlot(m[envOrder])
	if !ok {
		return false, nil // no/garbled ORDER: nothing to compare against
	}
	cur, err := c.CurrentSlot()
	if err != nil {
		// Can't prove a fallback; don't cry wolf. The engine's own
		// running-vs-target check still guards the commit.
		return false, nil
	}
	if head != cur {
		slog.Warn("boot health: running a different slot than the ORDER head — GRUB fell back",
			"ordered", head.String(), "running", cur.String())
		return true, nil
	}
	return false, nil
}

// VerifyPlatformUpdate is a no-op on this path: the GRUB binary is staged onto
// the ESP by a first-boot OS service, not carried in an OTA payload, so there
// is no in-payload bootloader update to verify. Cheap by contract.
func (c *Controller) VerifyPlatformUpdate(blUpdate bool) error {
	if blUpdate {
		slog.Info("platform verify: bootloader_update declared, but the grubenv connector has no in-payload platform-update path; skipping")
	}
	return nil
}

// AbortPlatformUpdate is a no-op: nothing is ever staged outside the grubenv,
// and the trial flag is reset by the rollback SwapSlot itself.
func (c *Controller) AbortPlatformUpdate() error { return nil }
