package tegrauefi

// Diagnostics for the `status` verb: rootfs/bootloader slots, the capsule
// (ESRT) outcome, and per-slot rootfs health. Every probe is best-effort —
// a failed read just omits its key, so `status` never errors on a quirky
// platform state.

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/wendylabsinc/wendy-os-update/internal/connector"
)

func (c *Controller) Diagnostics() map[string]string {
	d := map[string]string{}

	if s, err := c.CurrentSlot(); err == nil {
		d["rootfs_slot"] = s.String()
	}

	// Bootloader slot + version — the BOOTLOADER view of dump-slots-info
	// (no `-t rootfs`).
	if out, err := runCmd(c.Nvbootctrl, "dump-slots-info"); err == nil {
		for _, line := range strings.Split(out, "\n") {
			l := strings.TrimSpace(line)
			if v, ok := strings.CutPrefix(l, "Current version:"); ok {
				d["bootloader_version"] = strings.TrimSpace(v)
			}
			if v, ok := strings.CutPrefix(l, "Current bootloader slot:"); ok {
				d["bootloader_slot"] = strings.TrimSpace(v)
			}
		}
	}

	// ESRT entry0 — outcome of the last capsule (bootloader) update.
	esrtDir := filepath.Dir(c.RootDir + ESRTStatusPath)
	for key, file := range map[string]string{
		"esrt_last_attempt_status":      "last_attempt_status",
		"esrt_fw_version":               "fw_version",
		"esrt_lowest_supported_version": "lowest_supported_fw_version",
	} {
		if b, err := os.ReadFile(filepath.Join(esrtDir, file)); err == nil {
			d[key] = strings.TrimSpace(string(b))
		}
	}

	// Per-slot rootfs health efivar (normal vs unbootable).
	for _, s := range []connector.Slot{connector.SlotA, connector.SlotB} {
		if raw, err := readStatus(c.statusVar(s)); err == nil {
			if statusIsNormal(raw) {
				d["rootfs_status_"+s.String()] = "normal"
			} else {
				d["rootfs_status_"+s.String()] = "unbootable"
			}
		}
	}

	return d
}
