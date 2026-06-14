// Package engine sequences updates and owns the persistent state under
// /data/wendyos-update/ (schema: docs/state-schema.md, v1 frozen).
// One JSON file, atomic replace (write tmp + rename) — no database.
package engine

import "time"

// StateDir is the persistent state location (on the 'data' partition).
const StateDir = "/data/wendyos-update"

// Phase of a pending update.
type Phase string

const (
	// PhaseWritten: payload verified on the inactive slot, swap not yet done.
	PhaseWritten Phase = "written"
	// PhaseSwapped: slot swapped (or capsule staged); reboot pending or
	// commit pending after reboot.
	PhaseSwapped Phase = "swapped"
	// PhaseFailed: the verify unit (or commit) marked the deployment failed.
	PhaseFailed Phase = "failed"
)

// State is state.json — present only while an update is in flight.
// Ordering rules (power-cut safety) are specified in docs/state-schema.md.
type State struct {
	Schema           int       `json:"schema"`
	Phase            Phase     `json:"phase"`
	TargetSlot       int       `json:"target_slot"`
	ArtifactName     string    `json:"artifact_name"`
	ArtifactVersion  string    `json:"artifact_version"`
	PayloadSHA256    string    `json:"payload_sha256"`
	BootloaderUpdate bool      `json:"bootloader_update"`
	Created          time.Time `json:"created"`
}

// InstalledHistory is installed.json — committed artifacts, capped.
type InstalledHistory struct {
	History []InstalledEntry `json:"history"`
}

type InstalledEntry struct {
	ArtifactName    string    `json:"artifact_name"`
	ArtifactVersion string    `json:"artifact_version"`
	Committed       time.Time `json:"committed"`
	Slot            int       `json:"slot"`
}
