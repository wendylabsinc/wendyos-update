package engine

// Lifecycle hooks: product-defined executables run at fixed points in the
// update sequence (docs/cli-contract.md). Each phase P runs every regular,
// executable file in <HooksDir>/P.d in lexical order, with update context
// in the environment (WENDY_*). Gating phases (pre-install, post-install,
// health) abort the update on the first non-zero exit; advisory phases
// (post-commit, on-failure) only log. Network-independent by design:
// products gate on local app/service readiness, not connectivity.

import (
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"

	"github.com/wendylabsinc/wendy-os-update/internal/connector"
)

// DefaultHooksDir is the root holding the per-phase hook directories.
const DefaultHooksDir = "/etc/wendyos-update"

// Hook phases. The directory for a phase is <HooksDir>/<phase>.d.
const (
	HookPreInstall  = "pre-install"  // before writing the slot; non-zero aborts install
	HookPostInstall = "post-install" // after the swap, before reboot; non-zero aborts + unwinds
	HookHealth      = "health"       // commit gate, after platform verify; non-zero -> exit 4 -> rollback
	HookPostCommit  = "post-commit"  // after a successful commit; advisory (logged, never fatal)
	HookOnFailure   = "on-failure"   // a deployment was marked failed; advisory
)

// HookError reports a failing hook in a gating phase. cmd/wendyos-update maps
// it to an exit code (health -> 4, other gating phases -> 1).
type HookError struct {
	Phase string
	Hook  string
	Err   error
}

func (e *HookError) Error() string {
	return fmt.Sprintf("%s hook %q failed: %v", e.Phase, e.Hook, e.Err)
}

func (e *HookError) Unwrap() error { return e.Err }

// hookDir resolves a phase's hook directory. The health phase honours the
// legacy HealthDir override; every phase otherwise lives under HooksDir.
func (e *Engine) hookDir(phase string) string {
	if phase == HookHealth && e.HealthDir != "" {
		return e.HealthDir
	}
	root := e.HooksDir
	if root == "" {
		root = DefaultHooksDir
	}
	return filepath.Join(root, phase+".d")
}

// runHooks executes the phase's regular, executable files in lexical order,
// exporting WENDY_PHASE plus env to each. The first non-zero exit returns a
// *HookError. A missing or empty directory is a pass.
func (e *Engine) runHooks(phase string, env []string) error {
	dir := e.hookDir(phase)
	entries, err := os.ReadDir(dir)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read %s.d: %w", phase, err)
	}

	names := make([]string, 0, len(entries))
	for _, ent := range entries {
		if ent.IsDir() {
			continue
		}
		info, ierr := ent.Info()
		if ierr != nil || info.Mode()&0o111 == 0 {
			continue // skip non-executable files (READMEs, .conf, etc.)
		}
		names = append(names, ent.Name())
	}
	sort.Strings(names)

	hookEnv := append([]string{"WENDY_PHASE=" + phase}, env...)
	for _, name := range names {
		path := filepath.Join(dir, name)
		slog.Info("running hook", "phase", phase, "hook", name)
		cmd := exec.Command(path)
		cmd.Stdout = os.Stderr // hook output is human-facing
		cmd.Stderr = os.Stderr
		cmd.Env = append(os.Environ(), hookEnv...)
		if err := cmd.Run(); err != nil {
			return &HookError{Phase: phase, Hook: name, Err: err}
		}
	}
	return nil
}

// runAdvisoryHooks runs a non-gating phase: a failure is logged, never
// returned (post-commit, on-failure).
func (e *Engine) runAdvisoryHooks(phase string, env []string) {
	if err := e.runHooks(phase, env); err != nil {
		slog.Warn("advisory hook phase reported an error (ignored)", "phase", phase, "err", err)
	}
}

// hookEnv builds the update-context environment exposed to every hook
// (WENDY_PHASE is added per-phase by runHooks).
func (e *Engine) hookEnv(name, version string, target, cur connector.Slot, blUpdate bool) []string {
	return []string{
		"WENDY_ARTIFACT_NAME=" + name,
		"WENDY_ARTIFACT_VERSION=" + version,
		"WENDY_TARGET_SLOT=" + target.String(),
		"WENDY_CURRENT_SLOT=" + cur.String(),
		"WENDY_BOOTLOADER_UPDATE=" + strconv.FormatBool(blUpdate),
		"WENDY_STATE_DIR=" + e.StateDir,
	}
}
