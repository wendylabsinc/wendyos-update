package systemdboot

// Boot-health and platform-update verification (mirrors ubootenv/verify.go).
// systemd-boot's fallback verdict lives entirely in the loader entry file names
// on the ESP: an armed trial entry (a slot whose entry still carries a `+tries`
// counter) combined with running a DIFFERENT slot means systemd-boot exhausted
// the budget and fell back — the automatic rollback.

import (
	"log/slog"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// BootIsCompromised reports whether systemd-boot fell back during an armed trial.
// Signal: some slot's entry still carries a boot counter (a trial is in flight),
// yet the slot we are actually running is not that trial slot — i.e. the counter
// ran out and systemd-boot booted the other, counter-less slot. Once a trial
// commits, MarkGood drops the counter, so a committed system never reads as
// compromised.
//
// Conservative on uncertainty (best-effort, like the other connectors): any read
// error resolves to "not compromised" — the engine's own running-slot vs
// target-slot check remains the authoritative guard.
func (c *Controller) BootIsCompromised() (bool, error) {
	trial, ok := c.trialSlot()
	if !ok {
		return false, nil // no trial armed
	}
	cur, err := c.CurrentSlot()
	if err != nil {
		return false, nil // can't prove a fallback; don't cry wolf
	}
	if cur != trial {
		slog.Warn("boot health: a trial is armed but running a different slot than requested — systemd-boot fell back",
			"trial", trial.String(), "running", cur.String())
		return true, nil
	}
	return false, nil
}

// trialSlot returns the slot whose loader entry currently carries a `+tries`
// counter (the armed trial), if any. If both carry counters — an unusual state —
// the first found is returned; the caller only needs to know a trial exists.
func (c *Controller) trialSlot() (connector.Slot, bool) {
	for _, s := range []connector.Slot{connector.SlotA, connector.SlotB} {
		if e, err := c.findEntry(slotLetter(s)); err == nil && e.hasCounter() {
			return s, true
		}
	}
	return 0, false
}

// VerifyPlatformUpdate is a no-op in v1: this boot path has no in-payload
// bootloader/firmware update (systemd-boot itself and the Jetson QSPI firmware
// are updated out of band). Cheap by contract.
func (c *Controller) VerifyPlatformUpdate(blUpdate bool) error {
	if blUpdate {
		slog.Info("platform verify: bootloader_update declared, but the systemdboot connector has no in-payload platform-update path in v1; skipping")
	}
	return nil
}

// AbortPlatformUpdate is a no-op in v1: nothing is ever staged outside the ESP
// loader entries, and the trial is disarmed by the rollback SwapSlot itself.
func (c *Controller) AbortPlatformUpdate() error { return nil }
