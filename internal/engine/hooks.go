package engine

// Lifecycle hooks: product-defined executables run at fixed points in the
// update sequence (docs/cli-contract.md). Each phase P runs every regular,
// executable file in <HooksDir>/P.d in lexical order, with update context
// in the environment (WENDY_*). Gating phases (pre-install, post-install,
// health) abort the update on the first non-zero exit; advisory phases
// (post-commit, on-failure) only log. Network-independent by design:
// products gate on local app/service readiness, not connectivity.

import (
	"bytes"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

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

	if len(names) == 0 {
		slog.Debug("no hooks", "phase", phase, "dir", dir)
		return nil
	}

	hookEnv := append([]string{"WENDY_PHASE=" + phase}, env...)
	slog.Debug("hooks discovered", "phase", phase, "dir", dir,
		"count", len(names), "hooks", strings.Join(names, ","))
	slog.Debug("hook environment", "phase", phase, "env", strings.Join(hookEnv, " "))

	for _, name := range names {
		path := filepath.Join(dir, name)
		slog.Info("running hook", "phase", phase, "hook", name)
		cmd := exec.Command(path)
		// Tag the hook's own stdout/stderr with hook[<name>] and route it
		// through slog so it carries our journal severity prefix and is
		// greppable alongside the tool's output. Passing the SAME writer to
		// both streams makes os/exec serialize the two pipes' writes.
		hw := &hookLogWriter{name: name}
		cmd.Stdout = hw
		cmd.Stderr = hw
		cmd.Env = append(os.Environ(), hookEnv...)
		start := time.Now()
		err := cmd.Run()
		hw.flush()
		dur := time.Since(start).Round(time.Millisecond)
		if err != nil {
			slog.Error("hook failed", "phase", phase, "hook", name,
				"exit_code", exitCodeOf(err), "duration", dur, "err", err)
			return &HookError{Phase: phase, Hook: name, Err: err}
		}
		slog.Info("hook ok", "phase", phase, "hook", name, "duration", dur)
	}
	return nil
}

// exitCodeOf extracts the process exit code from a hook run error, or -1
// when the failure was not a non-zero exit (e.g. the binary could not be
// started — missing interpreter, not executable, permission denied).
func exitCodeOf(err error) int {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	return -1
}

// hookLogWriter buffers a hook's output and emits each complete line through
// slog tagged with hook[<name>], so hook output is attributable and carries
// the same journal severity/prefix as the tool's own logs. Partial trailing
// output is held until the next newline or a final flush(); empty lines are
// dropped to keep the journal clean.
type hookLogWriter struct {
	name string
	buf  []byte
}

func (w *hookLogWriter) Write(p []byte) (int, error) {
	w.buf = append(w.buf, p...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		w.emit(string(w.buf[:i]))
		w.buf = w.buf[i+1:]
	}
	return len(p), nil
}

func (w *hookLogWriter) flush() {
	if len(w.buf) > 0 {
		w.emit(string(w.buf))
		w.buf = nil
	}
}

func (w *hookLogWriter) emit(line string) {
	line = strings.TrimRight(line, "\r")
	if line == "" {
		return
	}
	slog.Info(fmt.Sprintf("hook[%s] %s", w.name, line))
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
