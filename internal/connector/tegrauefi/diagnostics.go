package tegrauefi

// Diagnostics for the `status` verb: rootfs/bootloader slots, the capsule
// (ESRT) outcome, and per-slot rootfs health. Every probe is best-effort —
// a failed read just omits its key, so `status` never errors on a quirky
// platform state. With verbose set, a fuller raw slot/EFI-variable snapshot
// is added for debugging (raw status bytes, per-slot bootloader state, the
// BootChainFw* variables, and the OsIndications capsule-arm bit).

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

func (c *Controller) Diagnostics(verbose bool) map[string]string {
	d := map[string]string{}

	if s, err := c.CurrentSlot(); err == nil {
		d["rootfs_slot"] = s.String()
	}

	// Bootloader slot + version — the BOOTLOADER view of dump-slots-info
	// (no `-t rootfs`). Captured once; the verbose pass re-parses it for
	// the per-slot detail lines.
	blInfo, _ := runCmd(c.Nvbootctrl, "dump-slots-info")
	for _, line := range strings.Split(blInfo, "\n") {
		l := strings.TrimSpace(line)
		if v, ok := strings.CutPrefix(l, "Current version:"); ok {
			d["bootloader_version"] = strings.TrimSpace(v)
		}
		if v, ok := strings.CutPrefix(l, "Current bootloader slot:"); ok {
			d["bootloader_slot"] = strings.TrimSpace(v)
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

	if verbose {
		c.verboseDiagnostics(d, blInfo)
	}
	return d
}

// verboseDiagnostics adds the raw slot/EFI-variable snapshot used for
// debugging (status --verbose). Every probe is best-effort.
func (c *Controller) verboseDiagnostics(d map[string]string, blInfo string) {
	// Raw RootfsStatusSlot bytes so a 0xFF (byte 4) is directly visible
	// alongside the normal|unbootable label.
	for _, s := range []connector.Slot{connector.SlotA, connector.SlotB} {
		if raw, err := readStatus(c.statusVar(s)); err == nil {
			d["rootfs_status_"+s.String()+"_raw"] = fmt.Sprintf("% x", raw)
		}
	}

	// Per-slot bootloader state (status / retry_count / priority), parsed
	// from the `slot: N, …` lines of dump-slots-info.
	for _, line := range strings.Split(blInfo, "\n") {
		l := strings.TrimSpace(line)
		rest, ok := strings.CutPrefix(l, "slot:")
		if !ok {
			continue
		}
		parts := strings.SplitN(strings.TrimSpace(rest), ",", 2)
		num := strings.TrimSpace(parts[0])
		detail := ""
		if len(parts) > 1 {
			detail = strings.Join(strings.Fields(parts[1]), " ")
		}
		d["bootloader_slot_"+num] = detail
	}

	// BootChainFw* variables (Current/Next/Status) drive the firmware A/B
	// bootloader-chain transitions a capsule triggers — a stale Next was
	// the crux of the 6163 investigation. Globbed so no GUID is hardcoded.
	if matches, err := filepath.Glob(filepath.Join(c.EfivarsDir, "BootChainFw*")); err == nil {
		for _, path := range matches {
			raw, err := os.ReadFile(path)
			if err != nil {
				continue
			}
			val := raw
			if len(raw) >= 4 { // skip the 4 attribute bytes
				val = raw[4:]
			}
			d[strings.ToLower(varStem(filepath.Base(path)))] = fmt.Sprintf("% x", val)
		}
	}

	// OsIndications: capsule-process bit (0x04) armed = "process capsule on
	// next boot". Shows the raw bytes plus the decoded arm state.
	osiPath := filepath.Join(c.EfivarsDir, "OsIndications-"+EfiGlobalGUID)
	if raw, err := os.ReadFile(osiPath); err == nil {
		armed := len(raw) >= 5 && raw[4]&osIndicationsProcessCapsule != 0
		d["osindications"] = fmt.Sprintf("% x (capsule_armed=%t)", raw, armed)
	}
}

// varStem strips the trailing "-<GUID>" from an efivarfs filename
// (e.g. "BootChainFwCurrent-<guid>" -> "BootChainFwCurrent").
func varStem(filename string) string {
	if i := strings.IndexByte(filename, '-'); i > 0 {
		return filename[:i]
	}
	return filename
}
