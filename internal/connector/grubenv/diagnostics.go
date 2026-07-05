package grubenv

// Display-only status detail for the `status` verb (mirrors
// ubootenv/diagnostics.go). Best-effort: never required for operation, and
// unreadable items are simply omitted.

import "github.com/wendylabsinc/wendyos-update/internal/connector"

// Diagnostics returns human-facing grubenv/slot detail. The non-verbose set is
// the GRUB variables that drive A/B selection; verbose adds the resolved
// per-slot rootfs devices.
func (c *Controller) Diagnostics(verbose bool) map[string]string {
	d := map[string]string{}
	if m, err := c.env.list(); err == nil {
		for _, k := range []string{
			envOrder,
			okKey(connector.SlotA), tryKey(connector.SlotA),
			okKey(connector.SlotB), tryKey(connector.SlotB),
		} {
			if v, ok := m[k]; ok && v != "" {
				d[k] = v
			}
		}
	}
	if !verbose {
		return d
	}
	for _, s := range []connector.Slot{connector.SlotA, connector.SlotB} {
		if dev, err := c.PartitionFor(s); err == nil {
			d["rootfs"+s.String()+"_dev"] = dev
		}
	}
	return d
}

// SlotStatus surfaces the per-slot signal the grubenv exposes: whether the slot
// is a known-good target (OK) and whether a one-shot trial of it is in flight
// (TRY). GRUB has no persistent per-slot rootfs health marker (unlike Tegra's
// RootfsStatusSlot), so RootfsHealth stays empty and the formatter omits it.
func (c *Controller) SlotStatus(s connector.Slot) connector.SlotStatus {
	var st connector.SlotStatus
	m, err := c.env.list()
	if err != nil {
		return st
	}
	if m[tryKey(s)] == "1" {
		st.Note = "trial armed"
	} else if m[okKey(s)] == "1" {
		st.Note = "known-good"
	}
	return st
}

// SystemStatus has no system-wide A/B detail to add on GRUB boards (the
// bootloader is shared, not per-slot, and carries no version we read here).
func (c *Controller) SystemStatus() []connector.KV { return nil }
