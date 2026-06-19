package ubootenv

// Display-only status detail for the `status` verb (mirrors
// tegrauefi/diagnostics.go). Best-effort: never required for operation,
// and unreadable items are simply omitted.

import "github.com/wendylabsinc/wendyos-update/internal/connector"

// Diagnostics returns human-facing env/slot detail. The non-verbose set is
// the U-Boot variables that drive A/B selection; verbose adds the resolved
// per-slot rootfs devices.
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
