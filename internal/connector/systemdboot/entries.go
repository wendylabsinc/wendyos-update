package systemdboot

// systemd-boot Automatic Boot Assessment lives in the loader ENTRY FILE NAME on
// the ESP, not in an EFI variable. A Type #1 entry `loader/entries/<id>.conf`
// carries its trial-boot retry budget as a `+tries[-done]` suffix on the file
// name:
//
//	slot-a.conf        no counter  -> permanent / "good" (always bootable)
//	slot-a+3.conf      tries_left=3, tries_done=0  (freshly armed trial)
//	slot-a+2-1.conf    tries_left=2, tries_done=1  (one attempt spent)
//	slot-a+0-3.conf    tries_left=0                 -> "bad" (deprioritized)
//
// systemd-boot (the EFI binary) decrements the counter by RENAMING the file on
// the FAT ESP just before it hands off to the kernel; when tries_left hits 0 the
// entry is marked bad and sorted last, so the loader falls through to the other
// slot's still-good entry — the automatic rollback. `systemd-bless-boot good`
// (or our MarkGood) renames the counter away to commit a slot permanently.
//
// Because the counter is a file-name rename on VFAT — NOT an EFI SetVariable —
// the boot-count state does not depend on NVIDIA edk2 persisting runtime EFI
// variables (the mechanism that is unarmable on Orin). That is the whole reason
// this scheme is viable on Jetson. See package doc for the residual EFI-var
// dependency (bootctl set-default/set-oneshot write LoaderEntryDefault/OneShot).

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// noCounter is the tries_left value used for an entry with no `+tries` suffix
// (a permanent / committed entry).
const noCounter = -1

// entry is one resolved loader entry file for a slot, with its parsed counter.
type entry struct {
	path string // absolute path to the .conf on the ESP
	left int    // tries_left; noCounter (-1) when the entry carries no counter
	done int    // tries_done; 0 when no counter
}

// hasCounter reports whether the entry carries a `+tries` boot-count suffix
// (i.e. a trial is in flight for this slot).
func (e entry) hasCounter() bool { return e.left != noCounter }

// isBad reports whether the entry has exhausted its retry budget (tries_left==0);
// systemd-boot deprioritizes such an entry, which is how a failed trial rolls
// back to the other slot.
func (e entry) isBad() bool { return e.left == 0 }

// entryID is the systemd-boot entry id for a slot ("slot-a"/"slot-b"). The id is
// the file name with the `.conf` extension AND the `+tries` counter stripped, so
// it is stable across boot-count renames — which is exactly what
// `bootctl set-default`/`set-oneshot` (LoaderEntryDefault/OneShot) match on.
func entryID(letter string) string { return "slot-" + letter }

// entryBase is the counter-less file name for a slot ("slot-a.conf").
func entryBase(letter string) string { return entryID(letter) + ".conf" }

// counterFilename renders a slot's entry file name for a given counter state.
// left==noCounter -> "slot-a.conf"; done==0 -> "slot-a+<left>.conf";
// otherwise "slot-a+<left>-<done>.conf". This mirrors systemd's own naming so a
// file we write is indistinguishable from one systemd-boot would have renamed.
func counterFilename(letter string, left, done int) string {
	if left == noCounter {
		return entryBase(letter)
	}
	if done == 0 {
		return fmt.Sprintf("%s+%d.conf", entryID(letter), left)
	}
	return fmt.Sprintf("%s+%d-%d.conf", entryID(letter), left, done)
}

// parseCounter extracts (tries_left, tries_done) from a loader entry file name.
// A name with no `+` suffix returns (noCounter, 0). An unparseable counter is
// treated as noCounter so a hand-edited file never crashes the OTA path.
func parseCounter(name string) (left, done int) {
	stem := strings.TrimSuffix(name, ".conf")
	plus := strings.IndexByte(stem, '+')
	if plus < 0 {
		return noCounter, 0
	}
	ctr := stem[plus+1:]
	if dash := strings.IndexByte(ctr, '-'); dash >= 0 {
		l, err1 := strconv.Atoi(ctr[:dash])
		d, err2 := strconv.Atoi(ctr[dash+1:])
		if err1 != nil || err2 != nil {
			return noCounter, 0
		}
		return l, d
	}
	l, err := strconv.Atoi(ctr)
	if err != nil {
		return noCounter, 0
	}
	return l, 0
}

// matchesSlot reports whether a loader entry file name belongs to the given slot
// id — the name is exactly "<id>.conf" or begins "<id>+" (a counter suffix). This
// guards the glob against a hypothetical unrelated entry that merely shares the
// "slot-a" prefix (e.g. "slot-alpha.conf").
func matchesSlot(name, id string) bool {
	if name == id+".conf" {
		return true
	}
	return strings.HasPrefix(name, id+"+")
}

// findEntry resolves the single loader entry file for slot letter, with its
// parsed counter. It is an error for the entry to be missing (a slot with no
// boot entry cannot be booted) or for more than one to match (ambiguous state a
// human must resolve, never silently guessed on an OTA path).
func (c *Controller) findEntry(letter string) (entry, error) {
	dir := c.entriesDir()
	matches, err := filepath.Glob(filepath.Join(dir, entryID(letter)+"*.conf"))
	if err != nil {
		return entry{}, fmt.Errorf("glob loader entries: %w", err)
	}
	var found []string
	for _, m := range matches {
		if matchesSlot(filepath.Base(m), entryID(letter)) {
			found = append(found, m)
		}
	}
	switch len(found) {
	case 0:
		return entry{}, fmt.Errorf("no loader entry for %q in %s", entryID(letter), dir)
	case 1:
		left, done := parseCounter(filepath.Base(found[0]))
		return entry{path: found[0], left: left, done: done}, nil
	default:
		return entry{}, fmt.Errorf("ambiguous loader entries for %q: %v", entryID(letter), found)
	}
}

// renameEntry renames a slot's resolved entry file to a new counter state,
// idempotently (a no-op when the file already has the wanted name). This is the
// exact operation systemd-boot and systemd-bless-boot perform; we do it
// natively so the connector is deterministic and unit-testable without a running
// systemd.
func (c *Controller) renameEntry(e entry, letter string, left, done int) error {
	want := filepath.Join(c.entriesDir(), counterFilename(letter, left, done))
	if e.path == want {
		return nil
	}
	if err := os.Rename(e.path, want); err != nil {
		return fmt.Errorf("rename %s -> %s: %w", filepath.Base(e.path), filepath.Base(want), err)
	}
	return nil
}
