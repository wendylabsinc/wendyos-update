package grubenv

// Display-only status detail for the `status` verb (mirrors
// ubootenv/diagnostics.go). Best-effort: never required for operation, and
// unreadable items are simply omitted.

import "github.com/wendylabsinc/wendyos-update/internal/connector"

// Diagnostics returns human-facing env/slot detail. The non-verbose set is the
// GRUB variables that drive A/B selection; verbose adds the resolved per-slot
// rootfs devices.
func (c *Controller) Diagnostics(verbose bool) map[string]string {
	d := map[string]string{}
	if v, err := c.env.get(envBootSlot); err == nil && v != "" {
		d["wendyos_boot_slot"] = v
	}
	if v, err := c.env.get(envUpgradeAvailable); err == nil && v != "" {
		d["wendyos_upgrade_available"] = v
	}
	if v, err := c.env.get(envBootCount); err == nil && v != "" {
		d["bootcount"] = v
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

// SlotStatus surfaces the only per-slot signal GRUB exposes: the trial state on
// the slot a trial is armed for. x86 has no persistent per-slot rootfs health
// marker (unlike Tegra's RootfsStatusSlot), so RootfsHealth stays empty and the
// formatter omits it.
func (c *Controller) SlotStatus(s connector.Slot) connector.SlotStatus {
	var st connector.SlotStatus
	armed, _ := c.env.get(envUpgradeAvailable)
	bootSlot, _ := c.env.get(envBootSlot)
	if armed == "1" && bootSlot == slotEnvValue(s) {
		st.Note = "trial armed"
		if bc, err := c.env.get(envBootCount); err == nil && bc != "" {
			st.Note = "trial armed (bootcount " + bc + ")"
		}
	}
	return st
}

// SystemStatus has no system-wide A/B detail to add on GRUB boards (the
// bootloader is shared, not per-slot, and carries no version we read here).
func (c *Controller) SystemStatus() []connector.KV { return nil }
