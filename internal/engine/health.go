package engine

// Boot-health gate for commit (docs/cli-contract.md: /etc/wendy-update/
// health.d/). The firmware-level check (verify-boot: slot status +
// double-boot, and running == target slot) is the always-on baseline.
// health.d adds product-defined, network-independent userspace checks on
// top: each executable in the directory is run in lexical order; a
// non-zero exit means the boot is not healthy and the update must not be
// committed. An absent or empty directory passes (firmware gate only).

import (
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
)

// DefaultHealthDir is where product health hooks live.
const DefaultHealthDir = "/etc/wendy-update/health.d"

// HealthCheckError reports a failing health hook. It maps to commit's
// exit code 4 (the deployment is marked failed, like a platform-verify
// failure — a subsequent reboot rolls back).
type HealthCheckError struct {
	Hook string
	Err  error
}

func (e *HealthCheckError) Error() string {
	return fmt.Sprintf("health check %q failed: %v", e.Hook, e.Err)
}

func (e *HealthCheckError) Unwrap() error { return e.Err }

// runHealthChecks executes every regular, executable file in dir in
// lexical order. The first non-zero exit fails the gate. A missing dir
// or no executables = pass.
func (e *Engine) runHealthChecks() error {
	dir := e.HealthDir
	if dir == "" {
		dir = DefaultHealthDir
	}
	entries, err := os.ReadDir(dir)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read health.d: %w", err)
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

	for _, name := range names {
		path := filepath.Join(dir, name)
		slog.Info("commit: running health check", "hook", name)
		cmd := exec.Command(path)
		cmd.Stdout = os.Stderr // hook output is human-facing
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return &HealthCheckError{Hook: name, Err: err}
		}
	}
	return nil
}
