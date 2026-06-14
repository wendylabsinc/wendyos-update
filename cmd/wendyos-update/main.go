// wendyos-update — generic A/B OTA tool for WendyOS.
// CLI contract: docs/cli-contract.md (v1, frozen).
//
// Exit codes: 0 ok · 1 error · 2 nothing-to-commit · 3 artifact rejected
// · 4 platform verification failed.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/wendylabsinc/wendy-os-update/internal/connector"
	_ "github.com/wendylabsinc/wendy-os-update/internal/connector/tegrauefi" // register
	"github.com/wendylabsinc/wendy-os-update/internal/engine"
	wlog "github.com/wendylabsinc/wendy-os-update/internal/log"
)

// HTTP timeouts for streaming installs. No overall client timeout — the
// payload is multi-GB and may legitimately stream for minutes — but each
// connection stage is bounded so a dead/unreachable server fails fast
// instead of hanging forever (the old http.Get default had none).
const (
	httpDialTimeout           = 30 * time.Second
	httpTLSHandshakeTimeout   = 30 * time.Second
	httpResponseHeaderTimeout = 60 * time.Second
)

var installHTTPClient = &http.Client{
	Transport: &http.Transport{
		DialContext:           (&net.Dialer{Timeout: httpDialTimeout}).DialContext,
		TLSHandshakeTimeout:   httpTLSHandshakeTimeout,
		ResponseHeaderTimeout: httpResponseHeaderTimeout,
	},
}

// ctxReader makes an in-progress read abort promptly when ctx is cancelled
// (Ctrl-C / systemd stop), without threading context through the block
// writer. For HTTP the request context already unblocks a blocked Read;
// this also covers local-file reads and tight copy loops.
type ctxReader struct {
	ctx context.Context
	r   io.Reader
}

func (c *ctxReader) Read(p []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.r.Read(p)
}

const version = "0.1.0-dev"

const configPath = "/etc/wendyos-update/config.json"

// Config is /etc/wendyos-update/config.json — everything optional.
type Config struct {
	Connector      string `json:"connector"`        // override auto-detect
	DeviceTypePath string `json:"device_type_path"` // override /etc/wendyos/device-type
	StateDir       string `json:"state_dir"`        // override /data/wendyos-update
	HooksDir       string `json:"hooks_dir"`        // override /etc/wendyos-update (root of <phase>.d dirs)
	HealthDir      string `json:"health_dir"`       // legacy: override the health phase dir only
}

// ui renders human-facing logs and the progress bar to stderr; stdout
// stays the machine-readable JSON channel (docs/cli-contract.md).
var ui *wlog.Logger

// stdoutIsTTY suppresses the high-frequency progress JSON when a human is
// watching stdout directly — machine callers always pipe stdout, so they
// still get it.
var stdoutIsTTY bool

func main() {
	ui = wlog.New(os.Stderr, wlog.Detect(os.Stderr))
	slog.SetDefault(ui.Slog())
	stdoutIsTTY = wlog.IsTTY(os.Stdout)

	// Cancel long operations (download/write) cleanly on Ctrl-C or a
	// systemd stop, instead of leaving a half-written slot on a hard kill.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	// Anchor every invocation in the log (version + verb) — correlates
	// journal entries across the verify/commit service boots.
	slog.Info("wendyos-update", "version", version, "verb", os.Args[1])

	var err error
	switch os.Args[1] {
	case "install":
		if len(os.Args) != 3 {
			fmt.Fprintln(os.Stderr, "usage: wendyos-update install <url|path>")
			os.Exit(1)
		}
		err = cmdInstall(ctx, os.Args[2])
	case "commit":
		err = cmdCommit()
	case "rollback":
		err = cmdRollback()
	case "status":
		statusArgs := os.Args[2:]
		err = cmdStatus(hasFlag(statusArgs, "--json"), hasFlag(statusArgs, "--verbose") || hasFlag(statusArgs, "-v"))
	case "mark-good":
		err = cmdMarkGood()
	case "pack":
		err = cmdPack(os.Args[2:])
	case "verify-boot":
		// Internal: wendyos-update-verify.service. Not in the public
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
		// "nothing to commit" is the normal every-boot outcome of the
		// auto-commit service (exit 2) — log it at info, not as an error,
		// so it does not show up red/high-priority in the journal.
		if errors.Is(err, engine.ErrNothingToCommit) {
			slog.Info(err.Error())
		} else {
			slog.Error(err.Error())
		}
		os.Exit(exitCode(err))
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `wendyos-update `+version+`
usage:
  wendyos-update install <url|path>   install a .wendy artifact (no reboot)
  wendyos-update commit               finalize after reboot (exit 2 = nothing to commit)
  wendyos-update rollback             swap back an uncommitted update
  wendyos-update status [--json] [--verbose]
                                      current slot / pending state (--verbose adds a raw slot/EFI-var snapshot)
  wendyos-update mark-good            reset slot health, clear pending state
  wendyos-update pack <flags>         build a .wendy artifact from a rootfs image (host-side)`)
}

// Contract exit codes (docs/cli-contract.md).
const (
	exitError           = 1 // generic error
	exitNothingToCommit = 2 // commit: nothing to commit (not an error)
	exitRejected        = 3 // artifact rejected (incompatible/bad/malformed)
	exitVerifyFailed    = 4 // platform or health verification failed at commit
)

// exitCode maps typed errors to contract exit codes (docs/cli-contract.md).
func exitCode(err error) int {
	if errors.Is(err, engine.ErrNothingToCommit) {
		return exitNothingToCommit
	}
	var rej *engine.RejectError
	if errors.As(err, &rej) {
		return exitRejected
	}
	var pv *engine.PlatformVerifyError
	if errors.As(err, &pv) {
		return exitVerifyFailed
	}
	var he *engine.HookError
	if errors.As(err, &he) {
		if he.Phase == engine.HookHealth {
			return exitVerifyFailed // a failed boot-health gate is a verification failure
		}
		return exitError // pre/post-install gate refused the update
	}
	return exitError
}

func loadConfig() Config {
	var cfg Config
	data, err := os.ReadFile(configPath)
	if err != nil {
		return cfg // absent config is fine: all defaults
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		slog.Warn("ignoring malformed config", "path", configPath, "err", err)
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
		HooksDir:       cfg.HooksDir,       // "" -> engine default (/etc/wendyos-update)
		HealthDir:      cfg.HealthDir,      // legacy health-phase override
		ToolVersion:    version,
		Progress:       emitProgress,
	}, nil
}

// emitProgress drives both progress channels: the contract's JSON lines
// on stdout (machine-readable ONLY — docs/cli-contract.md), and the
// human-facing bar/discrete lines on stderr via ui. The JSON is skipped
// when stdout is a terminal, where a human wants the bar, not JSON noise;
// machine callers pipe stdout, so they still receive it.
func emitProgress(phase string, percent int) {
	if !stdoutIsTTY {
		line, _ := json.Marshal(map[string]any{"phase": phase, "percent": percent})
		fmt.Println(string(line))
	}
	if ui != nil {
		ui.Progress(phase, percent)
	}
}

func cmdInstall(ctx context.Context, src string) error {
	eng, err := newEngine()
	if err != nil {
		return err
	}

	var reader io.Reader
	if strings.HasPrefix(src, "http://") || strings.HasPrefix(src, "https://") {
		emitProgress("download", -1)
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, src, nil)
		if err != nil {
			return fmt.Errorf("download: %w", err)
		}
		resp, err := installHTTPClient.Do(req)
		if err != nil {
			return fmt.Errorf("download: %w", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("download: %s returned %s", src, resp.Status)
		}
		slog.Info("install: downloading", "url", src, "status", resp.Status, "content_length", resp.ContentLength)
		reader = resp.Body
	} else {
		f, err := os.Open(src)
		if err != nil {
			return err
		}
		defer f.Close()
		reader = f
	}

	res, err := eng.Install(&ctxReader{ctx: ctx, r: reader})
	if err != nil {
		return err
	}
	// Machine JSON on stdout (suppressed when a human is watching a TTY).
	if !stdoutIsTTY {
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
	}
	// Human-readable line on stderr carries the same useful fields.
	slog.Info("install complete — reboot to activate",
		"artifact", res.ArtifactName, "version", res.ArtifactVersion,
		"target_slot", res.TargetSlot.String(), "bootloader_update", res.BootloaderUpdate,
		"reboot_required", true)
	return nil
}

// hasFlag reports whether name appears in args (order-independent flag
// parsing for the simple flag-only verbs).
func hasFlag(args []string, name string) bool {
	for _, a := range args {
		if a == name {
			return true
		}
	}
	return false
}

func cmdStatus(asJSON, verbose bool) error {
	eng, err := newEngine()
	if err != nil {
		return err
	}
	info, err := eng.Status(verbose)
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
	if len(info.Diagnostics) > 0 {
		keys := make([]string, 0, len(info.Diagnostics))
		for k := range info.Diagnostics {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		fmt.Fprintln(os.Stderr, "diagnostics:")
		for _, k := range keys {
			fmt.Fprintf(os.Stderr, "  %-30s %s\n", k, info.Diagnostics[k])
		}
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
	slog.Info("committed")
	return nil
}

func cmdRollback() error {
	eng, err := newEngine()
	if err != nil {
		return err
	}
	res, err := eng.Rollback()
	if err != nil {
		return err
	}
	// Machine JSON on stdout (suppressed when a human is watching a TTY);
	// the human-readable line is logged by the engine on stderr.
	if !stdoutIsTTY {
		line, _ := json.Marshal(map[string]any{
			"phase":           "rollback",
			"origin_slot":     res.OriginSlot.String(),
			"reboot_required": res.RebootRequired,
		})
		fmt.Println(string(line))
	}
	return nil
}

func cmdVerifyBoot() error {
	eng, err := newEngine()
	if err != nil {
		// Best-effort: a missing connector must not fail the boot.
		slog.Warn("verify-boot: skipped", "err", err)
		return nil
	}
	if err := eng.VerifyBoot(); err != nil {
		slog.Warn("verify-boot", "err", err)
	}
	return nil
}
