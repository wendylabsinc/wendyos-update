// wendy-update — generic A/B OTA tool for WendyOS.
// CLI contract: docs/cli-contract.md (v1, frozen).
//
// Exit codes: 0 ok · 1 error · 2 nothing-to-commit · 3 artifact rejected
// · 4 platform verification failed.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"

	"github.com/wendylabsinc/wendy-os-update/internal/connector"
	_ "github.com/wendylabsinc/wendy-os-update/internal/connector/tegrauefi" // register
	"github.com/wendylabsinc/wendy-os-update/internal/engine"
)

const version = "0.1.0-dev"

const configPath = "/etc/wendy-update/config.json"

// Config is /etc/wendy-update/config.json — everything optional.
type Config struct {
	Connector      string `json:"connector"`        // override auto-detect
	DeviceTypePath string `json:"device_type_path"` // override /etc/wendyos/device-type
	StateDir       string `json:"state_dir"`        // override /data/wendy-update
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	var err error
	switch os.Args[1] {
	case "install":
		if len(os.Args) != 3 {
			fmt.Fprintln(os.Stderr, "usage: wendy-update install <url|path>")
			os.Exit(1)
		}
		err = cmdInstall(os.Args[2])
	case "commit":
		err = cmdCommit()
	case "rollback":
		err = cmdRollback()
	case "status":
		err = cmdStatus(len(os.Args) > 2 && os.Args[2] == "--json")
	case "mark-good":
		err = cmdMarkGood()
	case "pack":
		err = cmdPack(os.Args[2:])
	case "verify-boot":
		// Internal: wendy-update-verify.service. Not in the public
		// contract; best-effort, never fails the boot.
		err = cmdVerifyBoot()
	case "version", "--version":
		fmt.Println(version)
		return
	default:
		usage()
		os.Exit(1)
	}

	if err != nil {
		fmt.Fprintln(os.Stderr, "wendy-update:", err)
		os.Exit(exitCode(err))
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `wendy-update `+version+`
usage:
  wendy-update install <url|path>   install a .wendy artifact (no reboot)
  wendy-update commit               finalize after reboot (exit 2 = nothing to commit)
  wendy-update rollback             swap back an uncommitted update
  wendy-update status [--json]      current slot / pending state
  wendy-update mark-good            reset slot health, clear pending state
  wendy-update pack <flags>         build a .wendy artifact from a rootfs image (host-side)`)
}

// exitCode maps typed errors to contract exit codes (docs/cli-contract.md).
func exitCode(err error) int {
	if errors.Is(err, engine.ErrNothingToCommit) {
		return 2
	}
	var rej *engine.RejectError
	if errors.As(err, &rej) {
		return 3
	}
	var pv *engine.PlatformVerifyError
	if errors.As(err, &pv) {
		return 4
	}
	return 1
}

func loadConfig() Config {
	var cfg Config
	data, err := os.ReadFile(configPath)
	if err != nil {
		return cfg // absent config is fine: all defaults
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		fmt.Fprintf(os.Stderr, "wendy-update: warning: ignoring malformed %s: %v\n", configPath, err)
	}
	return cfg
}

func newEngine() (*engine.Engine, error) {
	cfg := loadConfig()
	conn, err := connector.Select(cfg.Connector)
	if err != nil {
		return nil, err
	}
	stateDir := cfg.StateDir
	if stateDir == "" {
		stateDir = engine.StateDir
	}
	return &engine.Engine{
		Conn:           conn,
		StateDir:       stateDir,
		DeviceTypePath: cfg.DeviceTypePath, // "" -> engine default
		ToolVersion:    version,
		Progress:       emitProgress,
	}, nil
}

// emitProgress prints the contract's JSON lines on stdout
// (stdout is machine-readable ONLY — docs/cli-contract.md).
func emitProgress(phase string, percent int) {
	line, _ := json.Marshal(map[string]any{"phase": phase, "percent": percent})
	fmt.Println(string(line))
}

func cmdInstall(src string) error {
	eng, err := newEngine()
	if err != nil {
		return err
	}

	var reader io.Reader
	if strings.HasPrefix(src, "http://") || strings.HasPrefix(src, "https://") {
		emitProgress("download", -1)
		resp, err := http.Get(src)
		if err != nil {
			return fmt.Errorf("download: %w", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("download: %s returned %s", src, resp.Status)
		}
		reader = resp.Body
	} else {
		f, err := os.Open(src)
		if err != nil {
			return err
		}
		defer f.Close()
		reader = f
	}

	res, err := eng.Install(reader)
	if err != nil {
		return err
	}
	line, _ := json.Marshal(map[string]any{
		"phase":             "done",
		"percent":           100,
		"artifact_name":     res.ArtifactName,
		"artifact_version":  res.ArtifactVersion,
		"target_slot":       res.TargetSlot.String(),
		"bootloader_update": res.BootloaderUpdate,
		"reboot_required":   true,
	})
	fmt.Println(string(line))
	fmt.Fprintf(os.Stderr, "wendy-update: installed %s to slot %s — reboot to activate\n",
		res.ArtifactName, res.TargetSlot)
	return nil
}

func cmdStatus(asJSON bool) error {
	eng, err := newEngine()
	if err != nil {
		return err
	}
	info, err := eng.Status()
	if err != nil {
		return err
	}
	if asJSON {
		out, _ := json.MarshalIndent(info, "", "  ")
		fmt.Println(string(out))
		return nil
	}
	fmt.Fprintf(os.Stderr, "connector:    %s\ncurrent slot: %s\n", info.Connector, info.CurrentSlot)
	if info.Pending == nil {
		fmt.Fprintln(os.Stderr, "pending:      none")
	} else {
		fmt.Fprintf(os.Stderr, "pending:      %s (%s), phase %s, target slot %d\n",
			info.Pending.ArtifactName, info.Pending.ArtifactVersion, info.Pending.Phase, info.Pending.TargetSlot)
	}
	return nil
}

func cmdMarkGood() error {
	eng, err := newEngine()
	if err != nil {
		return err
	}
	return eng.MarkGood()
}

func cmdCommit() error {
	eng, err := newEngine()
	if err != nil {
		return err
	}
	if err := eng.Commit(); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "wendy-update: committed")
	return nil
}

func cmdRollback() error {
	eng, err := newEngine()
	if err != nil {
		return err
	}
	return eng.Rollback()
}

func cmdVerifyBoot() error {
	eng, err := newEngine()
	if err != nil {
		// Best-effort: a missing connector must not fail the boot.
		fmt.Fprintf(os.Stderr, "wendy-update: verify-boot: %v\n", err)
		return nil
	}
	if err := eng.VerifyBoot(); err != nil {
		fmt.Fprintf(os.Stderr, "wendy-update: verify-boot: %v\n", err)
	}
	return nil
}
