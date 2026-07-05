package systemdboot

// Display-only status detail for the `status` verb (mirrors ubootenv/tegrauefi
// diagnostics.go). Best-effort: never required for operation, and unreadable
// items are simply omitted.

import (
	"path/filepath"
	"strconv"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// Diagnostics returns human-facing slot/entry detail. The non-verbose set is the
// current slot and each slot's entry counter state; verbose adds the resolved
// entry file names, ESP path, and per-slot rootfs devices.
func (c *Controller) Diagnostics(verbose bool) map[string]string {
	d := map[string]string{}

	if s, err := c.CurrentSlot(); err == nil {
		d["rootfs_slot"] = s.String()
	}
	if trial, ok := c.trialSlot(); ok {
		d["trial_slot"] = trial.String()
	}

	for _, s := range []connector.Slot{connector.SlotA, connector.SlotB} {
		if e, err := c.findEntry(slotLetter(s)); err == nil {
			d["entry_"+s.String()] = entryState(e)
		}
	}

	if !verbose {
		return d
	}

	d["esp"] = c.ESPDir
	for _, s := range []connector.Slot{connector.SlotA, connector.SlotB} {
		if e, err := c.findEntry(slotLetter(s)); err == nil {
			d["entry_"+s.String()+"_file"] = filepath.Base(e.path)
		}
		if dev, err := c.PartitionFor(s); err == nil {
			d["rootfs"+s.String()+"_dev"] = dev
		}
	}
	return d
}

// entryState renders a loader entry's boot-count state for display.
func entryState(e entry) string {
	if !e.hasCounter() {
		return "good"
	}
	if e.isBad() {
		return "bad (0 tries left)"
	}
	return "trial (" + strconv.Itoa(e.left) + " tries left)"
}

// SlotStatus reports a slot's health from its loader entry: an exhausted counter
// (bad) reads as "unbootable"; a live counter surfaces the remaining tries and a
// trial note. A committed (counter-less) entry is "normal".
func (c *Controller) SlotStatus(s connector.Slot) connector.SlotStatus {
	var st connector.SlotStatus
	e, err := c.findEntry(slotLetter(s))
	if err != nil {
		return st
	}
	switch {
	case !e.hasCounter():
		st.RootfsHealth = "normal"
	case e.isBad():
		st.RootfsHealth = "unbootable"
	default:
		st.RootfsHealth = "normal"
		st.Retries = strconv.Itoa(e.left)
		st.Note = "trial armed"
	}
	return st
}

// SystemStatus has no system-wide A/B detail to add: systemd-boot's version and
// the loader config are not per-update state we surface here.
func (c *Controller) SystemStatus() []connector.KV { return nil }
