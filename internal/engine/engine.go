package engine

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/wendylabsinc/wendy-os-update/internal/artifact"
	"github.com/wendylabsinc/wendy-os-update/internal/blockdev"
	"github.com/wendylabsinc/wendy-os-update/internal/connector"
)

// DefaultDeviceTypePath is where WendyOS records the board identity
// (wendyos-identity recipe; key=value lines, the BOARD key).
const DefaultDeviceTypePath = "/etc/wendyos/device-type"

// RejectError marks an artifact-rejection condition: CLI exit code 3
// (docs/cli-contract.md). The slot was either untouched or only written
// — never swapped.
type RejectError struct{ Reason string }

func (e *RejectError) Error() string { return "artifact rejected: " + e.Reason }

func reject(format string, args ...any) error {
	return &RejectError{Reason: fmt.Sprintf(format, args...)}
}

// Progress receives coarse install progress for the CLI's JSON lines.
// percent is -1 when the total size is unknown.
type Progress func(phase string, percent int)

// Engine sequences updates over a connector. All paths are fields so
// tests can fake the platform completely.
type Engine struct {
	Conn           connector.Connector
	StateDir       string // default: StateDir const
	DeviceTypePath string // default: DefaultDeviceTypePath
	HooksDir       string // default: DefaultHooksDir; root for the per-phase hook dirs
	HealthDir      string // legacy override for the health phase only (config health_dir)
	ToolVersion    string
	Progress       Progress // may be nil
}

func (e *Engine) progress(phase string, percent int) {
	if e.Progress != nil {
		e.Progress(phase, percent)
	}
}

// InstallResult reports a successful install (up to "reboot required").
type InstallResult struct {
	ArtifactName     string         `json:"artifact_name"`
	ArtifactVersion  string         `json:"artifact_version"`
	TargetSlot       connector.Slot `json:"target_slot"`
	BootloaderUpdate bool           `json:"bootloader_update"`
}

// Install runs the full sequence of the `install` verb
// (docs/cli-contract.md): validate -> write inactive slot -> verify ->
// persist state -> prepare target -> swap. It never reboots.
func (e *Engine) Install(src io.Reader) (*InstallResult, error) {
	// One update in flight at a time.
	if st, err := e.LoadState(); err != nil {
		return nil, err
	} else if st != nil {
		return nil, fmt.Errorf("an update is already in flight (phase %q, artifact %s); run rollback or mark-good first", st.Phase, st.ArtifactName)
	}

	r, err := artifact.Open(src)
	if err != nil {
		return nil, reject("%v", err)
	}
	m := r.Manifest
	slog.Info("install: artifact opened",
		"artifact", m.ArtifactName, "version", m.ArtifactVersion,
		"bootloader_update", m.BootloaderUpdate)

	// Policy gates.
	devType, err := e.deviceType()
	if err != nil {
		return nil, err
	}
	if !m.CompatibleWith(devType) {
		return nil, reject("artifact targets %v, this device is %q", m.CompatibleDevices, devType)
	}
	if !versionAtLeast(e.ToolVersion, m.MinToolVersion) {
		return nil, reject("artifact requires tool >= %s, this is %s", m.MinToolVersion, e.ToolVersion)
	}
	slog.Info("install: artifact accepted", "device", devType)

	// Resolve the target slot.
	cur, err := e.Conn.CurrentSlot()
	if err != nil {
		return nil, err
	}
	target := cur.Other()
	dev, err := e.Conn.PartitionFor(target)
	if err != nil {
		return nil, err
	}

	// pre-install gate: products may refuse the update before anything is
	// written (custom compatibility / free-space / policy). A non-zero exit
	// aborts the install with nothing changed.
	env := e.hookEnv(m.ArtifactName, m.ArtifactVersion, target, cur, m.BootloaderUpdate)
	if err := e.runHooks(HookPreInstall, env); err != nil {
		return nil, err
	}

	slog.Info("install: writing rootfs to inactive slot",
		"current", cur.String(), "target", target.String(), "dev", dev,
		"size", m.Payload.Size)

	// Stream the payload onto the inactive slot.
	p, err := r.Payload()
	if err != nil {
		return nil, reject("%v", err)
	}
	e.progress("write", 0)
	writeStart := time.Now()
	var lastPct = -2
	written, digest, err := blockdev.WriteImage(dev, p, m.Payload.Compression, func(w int64) {
		pct := -1
		if m.Payload.Size > 0 {
			pct = int(w * 100 / m.Payload.Size)
			if pct > 100 {
				pct = 100
			}
		}
		if pct != lastPct {
			lastPct = pct
			e.progress("write", pct)
		}
	})
	if err != nil {
		return nil, fmt.Errorf("writing %s: %w", dev, err)
	}
	if secs := time.Since(writeStart).Seconds(); secs > 0 {
		slog.Info("install: rootfs written", "bytes", written,
			"seconds", int64(secs), "MB_per_s", int64(float64(written)/secs/1e6))
	}

	// Verify BEFORE persisting any state (state-schema.md ordering).
	e.progress("verify", -1)
	slog.Info("install: verifying payload", "written", written)
	if m.Payload.Size > 0 && written != m.Payload.Size {
		return nil, reject("payload size mismatch: wrote %d, manifest says %d", written, m.Payload.Size)
	}
	if err := r.VerifyPayloadDigests(digest); err != nil {
		return nil, reject("%v", err)
	}

	st := &State{
		Schema:           1,
		Phase:            PhaseWritten,
		TargetSlot:       int(target),
		ArtifactName:     m.ArtifactName,
		ArtifactVersion:  m.ArtifactVersion,
		PayloadSHA256:    m.Payload.SHA256,
		BootloaderUpdate: m.BootloaderUpdate,
		Created:          time.Now().UTC(),
	}
	if err := e.SaveState(st); err != nil {
		return nil, err
	}

	// Make the slot bootable, then swap.
	if err := e.Conn.PrepareTarget(target); err != nil {
		return nil, err // state stays phase=written; rollback/mark-good recovers
	}
	slog.Info("install: activating target slot", "target", target.String())
	e.progress("swap", -1)
	// Install swap: the connector inspects the freshly-written rootfs and
	// stages a platform update if it requests one (the rootfs marker is
	// authoritative, not m.BootloaderUpdate — see manifest-schema.md).
	if err := e.Conn.SwapSlot(target, true); err != nil {
		return nil, err // ditto
	}

	st.Phase = PhaseSwapped
	if err := e.SaveState(st); err != nil {
		return nil, err
	}

	// post-install hook (after the swap, before reboot). On failure, unwind
	// the staged update so the slot is left clean: drop any staged platform
	// update, re-point the active slot back to the running one, clear state.
	if err := e.runHooks(HookPostInstall, env); err != nil {
		slog.Warn("post-install hook failed; unwinding staged update", "err", err)
		if aerr := e.Conn.AbortPlatformUpdate(); aerr != nil {
			slog.Warn("unwind: abort platform update", "err", aerr)
		}
		if serr := e.Conn.SwapSlot(cur, false); serr != nil {
			slog.Warn("unwind: re-point active slot", "err", serr)
		}
		if cerr := e.ClearState(); cerr != nil {
			slog.Warn("unwind: clear state", "err", cerr)
		}
		return nil, err
	}

	return &InstallResult{
		ArtifactName:     m.ArtifactName,
		ArtifactVersion:  m.ArtifactVersion,
		TargetSlot:       target,
		BootloaderUpdate: m.BootloaderUpdate,
	}, nil
}

// StatusInfo is the `status` verb output (docs/cli-contract.md).
type StatusInfo struct {
	Connector   string            `json:"connector"`
	CurrentSlot string            `json:"current_slot"`
	Pending     *State            `json:"pending,omitempty"`
	Diagnostics map[string]string `json:"diagnostics,omitempty"`
}

func (e *Engine) Status(verbose bool) (*StatusInfo, error) {
	cur, err := e.Conn.CurrentSlot()
	if err != nil {
		return nil, err
	}
	st, err := e.LoadState()
	if err != nil {
		return nil, err
	}
	return &StatusInfo{
		Connector:   e.Conn.Name(),
		CurrentSlot: cur.String(),
		Pending:     st,
		Diagnostics: e.Conn.Diagnostics(verbose),
	}, nil
}

// MarkGood is the manual escape hatch: reset slot health, clear any
// pending state.
func (e *Engine) MarkGood() error {
	if err := e.Conn.MarkGood(); err != nil {
		return err
	}
	return e.ClearState()
}

// --- state persistence (schema: docs/state-schema.md) ---

func (e *Engine) statePath() string { return filepath.Join(e.StateDir, "state.json") }

// LoadState returns nil, nil when no update is in flight.
func (e *Engine) LoadState() (*State, error) {
	data, err := os.ReadFile(e.statePath())
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read state: %w", err)
	}
	var st State
	if err := json.Unmarshal(data, &st); err != nil {
		return nil, fmt.Errorf("parse %s: %w", e.statePath(), err)
	}
	return &st, nil
}

// SaveState persists atomically: write tmp, fsync, rename.
func (e *Engine) SaveState(st *State) error {
	if err := os.MkdirAll(e.StateDir, 0o755); err != nil {
		return fmt.Errorf("state dir: %w", err)
	}
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	tmp := e.statePath() + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return fmt.Errorf("write state: %w", err)
	}
	if _, err := f.Write(append(data, '\n')); err != nil {
		f.Close()
		return fmt.Errorf("write state: %w", err)
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return fmt.Errorf("sync state: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("close state: %w", err)
	}
	if err := os.Rename(tmp, e.statePath()); err != nil {
		return fmt.Errorf("commit state: %w", err)
	}
	return nil
}

func (e *Engine) ClearState() error {
	if err := os.Remove(e.statePath()); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("clear state: %w", err)
	}
	return nil
}

// --- policy helpers ---

// deviceType parses the BOARD key from /etc/wendyos/device-type
// (key=value lines, wendyos-identity recipe — verified format).
func (e *Engine) deviceType() (string, error) {
	path := e.DeviceTypePath
	if path == "" {
		path = DefaultDeviceTypePath
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("device type: %w", err)
	}
	for _, line := range strings.Split(string(data), "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "BOARD="); ok && v != "" {
			return v, nil
		}
	}
	return "", fmt.Errorf("device type: no BOARD= line in %s", path)
}

// versionAtLeast compares dotted numeric versions (pre-release suffixes
// after '-' are ignored). An empty or unparseable minimum gates nothing.
func versionAtLeast(have, min string) bool {
	if min == "" {
		return true
	}
	h, herr := parseVersion(have)
	m, merr := parseVersion(min)
	if merr != nil {
		return true // malformed gate must not brick updates
	}
	if herr != nil {
		return false
	}
	for i := 0; i < 3; i++ {
		if h[i] != m[i] {
			return h[i] > m[i]
		}
	}
	return true
}

func parseVersion(v string) ([3]int, error) {
	var out [3]int
	v, _, _ = strings.Cut(v, "-")
	parts := strings.Split(v, ".")
	if len(parts) != 3 {
		return out, fmt.Errorf("not a x.y.z version: %q", v)
	}
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil {
			return out, fmt.Errorf("not a x.y.z version: %q", v)
		}
		out[i] = n
	}
	return out, nil
}
