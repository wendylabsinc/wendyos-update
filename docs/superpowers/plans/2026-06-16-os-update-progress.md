# OS Update Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface live `wendy os update` progress (a real percent bar) in the CLI terminal, by teaching wendy-agent to run `wendy-update` and parse its stdout JSON, and the CLI to render percent.

**Architecture:** Add a dual auto-detect OTA backend to the agent (`wendy-update` preferred, `mender-update` fallback). For `wendy-update`, parse its stdout JSON progress lines (`{"phase","percent"}`, `percent==-1` = indeterminate) and forward the existing gRPC `Progress{phase,percent}`; mender keeps its stderr-regex path. The CLI swaps the install spinner for the existing `ProgressModel` bar and gains labels for wendy-update phases. No proto change.

**Tech Stack:** Go (`module github.com/wendylabsinc/wendy`), gRPC server-streaming, Bubble Tea TUI (`charmbracelet`), `go test`.

---

## Repo & scope note

- **All code changes are in the wendy-agent monorepo**, checked out at
  `/Users/joannisorlandos/git/wendy/wendyos`, already on branch
  `feature/agent-wendyos-update-backend`. `go.mod` is at the repo root
  (`module github.com/wendylabsinc/wendy`); code lives under `go/`. Run all
  `go` commands from `/Users/joannisorlandos/git/wendy/wendyos`.
- **`wendyos-update` (this repo) needs NO code change.** Its install path
  streams the artifact in one pass — the HTTP body is consumed lazily by
  `WriteImage`, so the existing `write` phase (0→100 against payload size)
  already reports the network transfer in real time. A separate "download
  percent" would be redundant and would fight the single CLI bar. (This
  supersedes the spec's section 2.)
- The proto `UpdateOSResponse.Progress{phase, percent}` is unchanged.

## File structure

| File | Responsibility | Action |
|---|---|---|
| `go/internal/agent/services/os_update_wendy.go` | wendy-update stdout-JSON progress parser + backend resolution | Create |
| `go/internal/agent/services/os_update_wendy_test.go` | Tests for parser + `resolveOTABinary` | Create |
| `go/internal/agent/services/os_update_service.go` | Branch `UpdateOS` on backend; extract mender path | Modify |
| `go/internal/agent/services/agent_service.go` | Advertise `"ota"` capability | Modify (`detectFeatureset` ~line 250-253) |
| `go/internal/cli/commands/os_cmd.go` | Percent rendering, phase labels, neutral gate | Modify |
| `go/internal/cli/commands/os_cmd_test.go` | Update for `ota` feature + renamed message | Modify |

---

## Task 1: wendy-update stdout progress parser

**Files:**
- Create: `/Users/joannisorlandos/git/wendy/wendyos/go/internal/agent/services/os_update_wendy.go`
- Test: `/Users/joannisorlandos/git/wendy/wendyos/go/internal/agent/services/os_update_wendy_test.go`

- [ ] **Step 1: Write the failing test**

Create `os_update_wendy_test.go`:

```go
package services

import (
	"reflect"
	"strings"
	"testing"
)

func TestScanWendyUpdateProgress(t *testing.T) {
	input := strings.Join([]string{
		`{"phase":"download","percent":-1}`,
		`{"phase":"write","percent":0}`,
		``,
		`not json`,
		`{"phase":"write","percent":57}`,
		`{"phase":"done","percent":100,"reboot_required":true}`,
	}, "\n")

	type ev struct {
		phase   string
		percent int32
	}
	var got []ev
	var bad []string

	err := scanWendyUpdateProgress(
		strings.NewReader(input),
		func(phase string, percent int32) { got = append(got, ev{phase, percent}) },
		func(line string) { bad = append(bad, line) },
	)
	if err != nil {
		t.Fatalf("scanWendyUpdateProgress: %v", err)
	}

	want := []ev{{"download", -1}, {"write", 0}, {"write", 57}, {"done", 100}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("events = %v, want %v", got, want)
	}
	if len(bad) != 1 || bad[0] != "not json" {
		t.Fatalf("bad lines = %v, want [\"not json\"]", bad)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/joannisorlandos/git/wendy/wendyos && go test ./go/internal/agent/services/ -run TestScanWendyUpdateProgress`
Expected: FAIL — `undefined: scanWendyUpdateProgress`.

- [ ] **Step 3: Write minimal implementation**

Create `os_update_wendy.go`:

```go
package services

import (
	"bufio"
	"encoding/json"
	"io"
)

// wendyUpdateLine is one stdout JSON progress line emitted by wendy-update
// (its docs/cli-contract.md). Extra fields on the terminal "done" line
// (artifact metadata, reboot_required) are ignored.
type wendyUpdateLine struct {
	Phase   string `json:"phase"`
	Percent int32  `json:"percent"`
}

// scanWendyUpdateProgress reads wendy-update's stdout JSON lines and calls
// send for each well-formed line (percent is -1 when indeterminate).
// Malformed or phase-less lines are passed to onBadLine and skipped: a parse
// error must never abort the update stream. Blank lines are ignored.
func scanWendyUpdateProgress(stdout io.Reader, send func(phase string, percent int32), onBadLine func(line string)) error {
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var p wendyUpdateLine
		if err := json.Unmarshal(line, &p); err != nil || p.Phase == "" {
			if onBadLine != nil {
				onBadLine(string(line))
			}
			continue
		}
		send(p.Phase, p.Percent)
	}
	return scanner.Err()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/joannisorlandos/git/wendy/wendyos && go test ./go/internal/agent/services/ -run TestScanWendyUpdateProgress`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/joannisorlandos/git/wendy/wendyos
git add go/internal/agent/services/os_update_wendy.go go/internal/agent/services/os_update_wendy_test.go
git commit -m "feat(agent): parse wendy-update stdout JSON progress"
```

---

## Task 2: OTA backend resolution (`resolveOTABinary`)

**Files:**
- Modify: `/Users/joannisorlandos/git/wendy/wendyos/go/internal/agent/services/os_update_wendy.go`
- Test: `/Users/joannisorlandos/git/wendy/wendyos/go/internal/agent/services/os_update_wendy_test.go`

- [ ] **Step 1: Write the failing test**

Append to `os_update_wendy_test.go`:

```go
import (
	"os"
	"path/filepath"
)

// (merge these imports into the existing import block)

func writeFakeExe(t *testing.T, path string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestResolveOTABinaryPrefersWendyUpdate(t *testing.T) {
	dir := t.TempDir()
	writeFakeExe(t, filepath.Join(dir, "wendy-update"))
	writeFakeExe(t, filepath.Join(dir, "mender-update"))
	t.Setenv("PATH", dir)

	path, kind, found := resolveOTABinary()
	if !found || kind != backendWendyUpdate {
		t.Fatalf("found=%v kind=%v, want backendWendyUpdate", found, kind)
	}
	if filepath.Base(path) != "wendy-update" {
		t.Fatalf("path=%q, want .../wendy-update", path)
	}
}

func TestResolveOTABinaryFallsBackToMender(t *testing.T) {
	dir := t.TempDir()
	writeFakeExe(t, filepath.Join(dir, "mender-update"))
	t.Setenv("PATH", dir)

	path, kind, found := resolveOTABinary()
	if !found || kind != backendMender {
		t.Fatalf("found=%v kind=%v, want backendMender", found, kind)
	}
	if filepath.Base(path) != "mender-update" {
		t.Fatalf("path=%q, want .../mender-update", path)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/joannisorlandos/git/wendy/wendyos && go test ./go/internal/agent/services/ -run TestResolveOTABinary`
Expected: FAIL — `undefined: resolveOTABinary`, `undefined: backendWendyUpdate`.

- [ ] **Step 3: Write minimal implementation**

Append to `os_update_wendy.go` (add `"os"`, `"os/exec"`, `"path/filepath"` to its imports):

```go
// otaBackend identifies which OTA tool the agent shells out to.
type otaBackend int

const (
	backendNone otaBackend = iota
	backendWendyUpdate
	backendMender
)

// resolveOTABinary finds the OTA update binary, preferring wendy-update over
// the legacy mender-update so JetPack 7+ devices use the new tool while
// mender-only devices keep working. Mirrors resolveMenderBinary's probing:
// PATH via exec.LookPath, then absolute-path os.Stat (absolute paths only, so
// nothing from the cwd is ever executed).
func resolveOTABinary() (string, otaBackend, bool) {
	wendyCandidates := []string{
		"wendy-update",
		"/usr/local/sbin/wendy-update",
		"/usr/local/bin/wendy-update",
		"/usr/sbin/wendy-update",
		"/usr/bin/wendy-update",
		"/sbin/wendy-update",
		"/bin/wendy-update",
	}
	for _, c := range wendyCandidates {
		if path, err := exec.LookPath(c); err == nil {
			return path, backendWendyUpdate, true
		}
		if filepath.IsAbs(c) {
			if _, err := os.Stat(c); err == nil {
				return c, backendWendyUpdate, true
			}
		}
	}
	if path, found := resolveMenderBinary(); found {
		return path, backendMender, true
	}
	return "", backendNone, false
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/joannisorlandos/git/wendy/wendyos && go test ./go/internal/agent/services/ -run TestResolveOTABinary`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/joannisorlandos/git/wendy/wendyos
git add go/internal/agent/services/os_update_wendy.go go/internal/agent/services/os_update_wendy_test.go
git commit -m "feat(agent): resolveOTABinary prefers wendy-update over mender"
```

---

## Task 3: Wire `UpdateOS` to the dual backend

**Files:**
- Modify: `/Users/joannisorlandos/git/wendy/wendyos/go/internal/agent/services/os_update_service.go`

This refactors the existing `UpdateOS` so the shared preamble (host check, Jetson A/B setup, backend resolution) stays in `UpdateOS`, the existing mender flow moves verbatim into `runMenderInstall`, and a new `runWendyUpdateInstall` handles the wendy-update path by parsing stdout JSON. No behavior change for mender devices.

- [ ] **Step 1: Replace the body of `UpdateOS`**

In `os_update_service.go`, replace the current `UpdateOS` method (from `sendProgress := func(...)` through the final `Completed` send, i.e. lines ~38-126) with the dispatcher below. Keep the host-check and `enableJetsonRootfsAB` blocks above it unchanged.

```go
	// (host check + enableJetsonRootfsAB block stays unchanged above)

	binary, kind, found := resolveOTABinary()
	if !found {
		return stream.Send(&agentpbv2.UpdateOSResponse{
			ResponseType: &agentpbv2.UpdateOSResponse_Failed_{
				Failed: &agentpbv2.UpdateOSResponse_Failed{
					ErrorMessage: "no OTA update backend (wendy-update or mender-update) found",
				},
			},
		})
	}

	if kind == backendWendyUpdate {
		return s.runWendyUpdateInstall(stream, binary, req.GetArtifactUrl())
	}
	return s.runMenderInstall(stream, binary, req.GetArtifactUrl())
}
```

- [ ] **Step 2: Add `runMenderInstall` (existing mender logic, moved)**

Add this method. Its body is the current mender flow verbatim — the `sendProgress` closure, `sendProgress("downloading", 0)`, `exec.CommandContext(... "install" ...)`, the `StderrPipe` scan with `menderProgressRe`, `cmd.Wait()` + `formatMenderFailure`, and the final `Completed` send:

```go
func (s *OSUpdateService) runMenderInstall(stream grpc.ServerStreamingServer[agentpbv2.UpdateOSResponse], binary, artifactURL string) error {
	sendProgress := func(phase string, percent int32) {
		_ = stream.Send(&agentpbv2.UpdateOSResponse{
			ResponseType: &agentpbv2.UpdateOSResponse_Progress_{
				Progress: &agentpbv2.UpdateOSResponse_Progress{Phase: phase, Percent: percent},
			},
		})
	}

	sendProgress("downloading", 0)

	cmd := exec.CommandContext(stream.Context(), binary, "install", artifactURL)
	cmd.Env = envWithPath("/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")

	stderr, err := cmd.StderrPipe()
	if err != nil {
		return stream.Send(&agentpbv2.UpdateOSResponse{
			ResponseType: &agentpbv2.UpdateOSResponse_Failed_{
				Failed: &agentpbv2.UpdateOSResponse_Failed{
					ErrorMessage: fmt.Sprintf("failed to create stderr pipe: %v", err),
				},
			},
		})
	}

	if err := cmd.Start(); err != nil {
		return stream.Send(&agentpbv2.UpdateOSResponse{
			ResponseType: &agentpbv2.UpdateOSResponse_Failed_{
				Failed: &agentpbv2.UpdateOSResponse_Failed{
					ErrorMessage: fmt.Sprintf("failed to start mender: %v", err),
				},
			},
		})
	}

	outputTail := newLineRing(menderErrorTailLines)
	scanner := bufio.NewScanner(stderr)
	for scanner.Scan() {
		line := scanner.Text()
		outputTail.push(line)
		if m := menderProgressRe.FindStringSubmatch(line); len(m) > 1 {
			if pct := parseInt32(m[1]); pct >= 0 {
				sendProgress("installing", pct)
			}
		}
	}
	if err := scanner.Err(); err != nil {
		s.logger.Warn("mender output scan error", zap.Error(err))
	}

	if err := cmd.Wait(); err != nil {
		msg := formatOTAFailure(err, outputTail.tail())
		s.logger.Error("mender install failed", zap.Error(err), zap.Strings("output_tail", outputTail.tail()))
		return stream.Send(&agentpbv2.UpdateOSResponse{
			ResponseType: &agentpbv2.UpdateOSResponse_Failed_{
				Failed: &agentpbv2.UpdateOSResponse_Failed{ErrorMessage: msg},
			},
		})
	}

	return stream.Send(&agentpbv2.UpdateOSResponse{
		ResponseType: &agentpbv2.UpdateOSResponse_Completed_{
			Completed: &agentpbv2.UpdateOSResponse_Completed{RebootRequired: true},
		},
	})
}
```

- [ ] **Step 3: Add `runWendyUpdateInstall` (stdout JSON path)**

```go
func (s *OSUpdateService) runWendyUpdateInstall(stream grpc.ServerStreamingServer[agentpbv2.UpdateOSResponse], binary, artifactURL string) error {
	sendProgress := func(phase string, percent int32) {
		_ = stream.Send(&agentpbv2.UpdateOSResponse{
			ResponseType: &agentpbv2.UpdateOSResponse_Progress_{
				Progress: &agentpbv2.UpdateOSResponse_Progress{Phase: phase, Percent: percent},
			},
		})
	}

	sendProgress("download", 0)

	cmd := exec.CommandContext(stream.Context(), binary, "install", artifactURL)
	cmd.Env = envWithPath("/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")

	// wendy-update separates streams: progress JSON on stdout, human logs on
	// stderr. Capture the stderr tail for failure diagnostics, parse stdout
	// for progress.
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return stream.Send(&agentpbv2.UpdateOSResponse{
			ResponseType: &agentpbv2.UpdateOSResponse_Failed_{
				Failed: &agentpbv2.UpdateOSResponse_Failed{
					ErrorMessage: fmt.Sprintf("failed to create stdout pipe: %v", err),
				},
			},
		})
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return stream.Send(&agentpbv2.UpdateOSResponse{
			ResponseType: &agentpbv2.UpdateOSResponse_Failed_{
				Failed: &agentpbv2.UpdateOSResponse_Failed{
					ErrorMessage: fmt.Sprintf("failed to create stderr pipe: %v", err),
				},
			},
		})
	}

	if err := cmd.Start(); err != nil {
		return stream.Send(&agentpbv2.UpdateOSResponse{
			ResponseType: &agentpbv2.UpdateOSResponse_Failed_{
				Failed: &agentpbv2.UpdateOSResponse_Failed{
					ErrorMessage: fmt.Sprintf("failed to start wendy-update: %v", err),
				},
			},
		})
	}

	outputTail := newLineRing(menderErrorTailLines)
	go func() {
		sc := bufio.NewScanner(stderr)
		for sc.Scan() {
			outputTail.push(sc.Text())
		}
	}()

	if scanErr := scanWendyUpdateProgress(stdout, sendProgress, func(line string) {
		s.logger.Warn("unparseable wendy-update progress line", zap.String("line", line))
	}); scanErr != nil {
		s.logger.Warn("wendy-update stdout scan error", zap.Error(scanErr))
	}

	if err := cmd.Wait(); err != nil {
		msg := formatOTAFailure(err, outputTail.tail())
		s.logger.Error("wendy-update install failed", zap.Error(err), zap.Strings("output_tail", outputTail.tail()))
		return stream.Send(&agentpbv2.UpdateOSResponse{
			ResponseType: &agentpbv2.UpdateOSResponse_Failed_{
				Failed: &agentpbv2.UpdateOSResponse_Failed{ErrorMessage: msg},
			},
		})
	}

	return stream.Send(&agentpbv2.UpdateOSResponse{
		ResponseType: &agentpbv2.UpdateOSResponse_Completed_{
			Completed: &agentpbv2.UpdateOSResponse_Completed{RebootRequired: true},
		},
	})
}
```

- [ ] **Step 4: Rename `formatMenderFailure` → `formatOTAFailure`**

In `/Users/joannisorlandos/git/wendy/wendyos/go/internal/agent/services/mender_output.go`, rename the function and update its doc comment to be backend-neutral:

```go
// formatOTAFailure builds the user-facing error for a failed OTA install,
// appending the captured tail of the tool's output when available. Without the
// tail this degrades to a bare "exit status N".
func formatOTAFailure(waitErr error, tail []string) string {
	if len(tail) == 0 {
		return fmt.Sprintf("OS update failed: %v", waitErr)
	}
	return fmt.Sprintf("OS update failed: %v\noutput:\n%s", waitErr, strings.Join(tail, "\n"))
}
```

Update the two callers in `mender_output_test.go` (`TestFormatMenderFailureWithoutOutput`, `TestFormatMenderFailureIncludesOutput`) to call `formatOTAFailure` and expect the new prefix `"OS update failed: exit status 1"`. Also update the other existing caller at `agent_service.go:754` area (search for `formatMenderFailure` and replace all occurrences with `formatOTAFailure`).

- [ ] **Step 5: Verify it builds and the package tests pass**

Run: `cd /Users/joannisorlandos/git/wendy/wendyos && grep -rn "formatMenderFailure" go/ ; go build ./go/... && go test ./go/internal/agent/services/`
Expected: the grep returns nothing; build succeeds; tests PASS (including the renamed `formatOTAFailure` tests and the line-ring tests).

- [ ] **Step 6: Commit**

```bash
cd /Users/joannisorlandos/git/wendy/wendyos
git add go/internal/agent/services/os_update_service.go go/internal/agent/services/mender_output.go go/internal/agent/services/mender_output_test.go go/internal/agent/services/agent_service.go
git commit -m "feat(agent): dual OTA backend in UpdateOS (wendy-update stdout + mender)"
```

---

## Task 4: Advertise the `ota` capability

**Files:**
- Modify: `/Users/joannisorlandos/git/wendy/wendyos/go/internal/agent/services/agent_service.go` (`detectFeatureset`, ~lines 250-253)

- [ ] **Step 1: Update `detectFeatureset`**

Find the existing block (around line 251):

```go
	if _, found := resolveMenderBinary(); found {
		features = append(features, "mender")
	}
```

Replace it with (keep advertising `"mender"` for back-compat; add `"ota"` whenever any backend is present):

```go
	if _, found := resolveMenderBinary(); found {
		features = append(features, "mender")
	}
	if _, _, found := resolveOTABinary(); found {
		features = append(features, "ota")
	}
```

- [ ] **Step 2: Verify build**

Run: `cd /Users/joannisorlandos/git/wendy/wendyos && go build ./go/...`
Expected: success.

- [ ] **Step 3: Commit**

```bash
cd /Users/joannisorlandos/git/wendy/wendyos
git add go/internal/agent/services/agent_service.go
git commit -m "feat(agent): advertise ota capability when an OTA backend is present"
```

---

## Task 5: CLI phase labels + progress mapper

**Files:**
- Modify: `/Users/joannisorlandos/git/wendy/wendyos/go/internal/cli/commands/os_cmd.go`
- Test: `/Users/joannisorlandos/git/wendy/wendyos/go/internal/cli/commands/os_cmd_test.go`

- [ ] **Step 1: Write the failing test**

Append to `os_cmd_test.go` (the file already imports `testing`; add `"github.com/wendylabsinc/wendy/go/internal/cli/tui"` to its import block):

```go
func TestPhaseLabelWendyUpdatePhases(t *testing.T) {
	cases := map[string]string{
		"download":   "Downloading update...",
		"write":      "Writing image...",
		"verify":     "Verifying...",
		"swap":       "Switching boot slot...",
		"done":       "Finalizing...",
		"installing": "Installing update...", // mender phase, unchanged
	}
	for phase, want := range cases {
		if got := phaseLabel(phase); got != want {
			t.Errorf("phaseLabel(%q) = %q, want %q", phase, got, want)
		}
	}
}

func TestOSUpdateProgressMsg(t *testing.T) {
	// Determinate: sets percent and advances lastPercent.
	msg, last := osUpdateProgressMsg("write", 57, 0.10)
	if msg.Percent != 0.57 || last != 0.57 {
		t.Fatalf("write 57: percent=%v last=%v, want 0.57/0.57", msg.Percent, last)
	}
	if msg.Title != "Writing image..." {
		t.Fatalf("write title=%q", msg.Title)
	}
	// Indeterminate (-1): holds the last percent so the bar does not snap to 0.
	msg, last = osUpdateProgressMsg("verify", -1, 0.57)
	if msg.Percent != 0.57 || last != 0.57 {
		t.Fatalf("verify -1: percent=%v last=%v, want 0.57/0.57", msg.Percent, last)
	}
	if msg.Title != "Verifying..." {
		t.Fatalf("verify title=%q", msg.Title)
	}
	_ = tui.ProgressUpdateMsg{} // ensure tui import is used
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/joannisorlandos/git/wendy/wendyos && go test ./go/internal/cli/commands/ -run 'TestPhaseLabelWendyUpdatePhases|TestOSUpdateProgressMsg'`
Expected: FAIL — `undefined: osUpdateProgressMsg` and label mismatches for the new phases.

- [ ] **Step 3: Extend `phaseLabel` and add `osUpdateProgressMsg`**

In `os_cmd.go`, replace the existing `phaseLabel` function (line ~559) with:

```go
// phaseLabel converts a wendy-update or mender phase string to a user-friendly
// progress label.
func phaseLabel(phase string) string {
	switch phase {
	case "download", "downloading":
		return "Downloading update..."
	case "write":
		return "Writing image..."
	case "verify":
		return "Verifying..."
	case "swap":
		return "Switching boot slot..."
	case "installing":
		return "Installing update..."
	case "done", "finalizing":
		return "Finalizing..."
	default:
		if phase != "" {
			return strings.ToUpper(phase[:1]) + phase[1:] + "..."
		}
		return "Updating WendyOS..."
	}
}
```

Add the mapper near `phaseLabel` (add `"github.com/wendylabsinc/wendy/go/internal/cli/tui"` to the file's imports if not already present — it is, via the spinner usage):

```go
// osUpdateProgressMsg maps a streamed Progress (phase + percent, where -1 means
// indeterminate) to a TUI progress update. lastPercent is carried forward so
// the bar holds steady during indeterminate phases (verify/swap) instead of
// snapping back to 0; the returned float is the new lastPercent.
func osUpdateProgressMsg(phase string, percent int32, lastPercent float64) (tui.ProgressUpdateMsg, float64) {
	p := lastPercent
	if percent >= 0 {
		p = float64(percent) / 100
	}
	return tui.ProgressUpdateMsg{Title: phaseLabel(phase), Percent: p}, p
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/joannisorlandos/git/wendy/wendyos && go test ./go/internal/cli/commands/ -run 'TestPhaseLabelWendyUpdatePhases|TestOSUpdateProgressMsg'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/joannisorlandos/git/wendy/wendyos
git add go/internal/cli/commands/os_cmd.go go/internal/cli/commands/os_cmd_test.go
git commit -m "feat(cli): phase labels + percent mapper for OS update progress"
```

---

## Task 6: CLI render percent bar + backend-neutral gate

**Files:**
- Modify: `/Users/joannisorlandos/git/wendy/wendyos/go/internal/cli/commands/os_cmd.go`
- Test: `/Users/joannisorlandos/git/wendy/wendyos/go/internal/cli/commands/os_cmd_test.go`

- [ ] **Step 1: Update the gating test (failing)**

In `os_cmd_test.go`, change the `want:` on the "WendyOS without mender is unsupported" case from `wendyOSMissingMenderMessage` to `osUpdateNoBackendMessage`, and add a new supported case for the `ota` feature:

```go
		{
			name: "WendyOS without an OTA backend is unsupported",
			resp: &agentpb.GetAgentVersionResponse{Os: "linux", OsVersion: strp("WendyOS-0.10.4")},
			want: osUpdateNoBackendMessage,
		},
		{
			name: "WendyOS with ota feature is supported",
			resp: &agentpb.GetAgentVersionResponse{Os: "linux", OsVersion: strp("WendyOS-0.10.4"), Featureset: []string{"ota"}},
		},
```

(Keep the existing two `["mender"]`-supported cases — they must still pass.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/joannisorlandos/git/wendy/wendyos && go test ./go/internal/cli/commands/ -run TestValidateOSUpdate`
Expected: FAIL — `undefined: osUpdateNoBackendMessage` (and the old `wendyOSMissingMenderMessage` constant no longer referenced).

> If the test function name differs, find it with:
> `grep -n "func Test.*ValidateOSUpdate\|func Test.*validateOSUpdate" go/internal/cli/commands/os_cmd_test.go`

- [ ] **Step 3: Rename the message constant and relax the gate**

In `os_cmd.go`, replace the `wendyOSMissingMenderMessage` constant (line ~44) with:

```go
	osUpdateNoBackendMessage = "This WendyOS image does not support OTA updates because no update backend (wendy-update or mender-update) was found. Reinstall or upgrade to a WendyOS image with OTA support."
```

Replace `validateOSUpdateTarget` (line ~57) with:

```go
func validateOSUpdateTarget(versionResp *agentpb.GetAgentVersionResponse) error {
	if err := validateOSUpdateIdentity(versionResp); err != nil {
		return err
	}
	if !agentVersionHasFeature(versionResp, "ota") && !agentVersionHasFeature(versionResp, "mender") {
		return errors.New(osUpdateNoBackendMessage)
	}
	return nil
}
```

- [ ] **Step 4: Swap the install spinner for the progress bar**

In `newOSUpdateCmd`'s `RunE`, replace the interactive block (currently lines ~240-282, the `if isInteractiveTerminal() { spin := tui.NewSpinner(...) ... }` branch, up to but NOT including the `} else {` that calls `drainOSUpdateStream`) with:

```go
			if isInteractiveTerminal() {
				prog := tui.NewProgress("Preparing update...")
				p := tea.NewProgram(prog)

				go func() {
					var lastPercent float64
					for {
						resp, err := stream.Recv()
						if err == io.EOF {
							p.Send(tui.ProgressDoneMsg{})
							return
						}
						if err != nil {
							p.Send(tui.ProgressDoneMsg{Err: err})
							return
						}
						if progress := resp.GetProgress(); progress != nil {
							var msg tui.ProgressUpdateMsg
							msg, lastPercent = osUpdateProgressMsg(progress.GetPhase(), progress.GetPercent(), lastPercent)
							p.Send(msg)
						}
						if resp.GetCompleted() != nil {
							p.Send(tui.ProgressDoneMsg{})
							return
						}
						if failed := resp.GetFailed(); failed != nil {
							p.Send(tui.ProgressDoneMsg{Err: fmt.Errorf("update failed: %s", failed.GetErrorMessage())})
							return
						}
					}
				}()

				finalModel, err := p.Run()
				if err != nil {
					return fmt.Errorf("TUI error: %w", err)
				}
				model, ok := finalModel.(tui.ProgressModel)
				if !ok {
					return fmt.Errorf("TUI error: unexpected model type %T", finalModel)
				}
				if err := model.Err(); err != nil {
					return err
				}
			} else {
				if err := drainOSUpdateStream(stream); err != nil {
					return err
				}
			}
```

Note: this drops the `SpinnerModel`-specific `ErrUserCancelled`/`spinModel.Done()` handling; with `ProgressModel`, a user cancel (`q`/`ctrl+c`) surfaces as `context.Canceled` from `model.Err()`, which is returned. This is acceptable and keeps the cancel path working.

- [ ] **Step 5: Build and run the full package tests**

Run: `cd /Users/joannisorlandos/git/wendy/wendyos && grep -rn "wendyOSMissingMenderMessage" go/ ; go build ./go/... && go test ./go/internal/cli/commands/ ./go/internal/agent/services/`
Expected: grep returns nothing; build succeeds; all tests PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/joannisorlandos/git/wendy/wendyos
git add go/internal/cli/commands/os_cmd.go go/internal/cli/commands/os_cmd_test.go
git commit -m "feat(cli): render percent bar for OS update; accept ota capability"
```

---

## Task 7: Whole-repo verification

- [ ] **Step 1: Build everything and vet**

Run: `cd /Users/joannisorlandos/git/wendy/wendyos && go build ./go/... && go vet ./go/internal/agent/services/... ./go/internal/cli/commands/...`
Expected: no errors.

- [ ] **Step 2: Run the affected tests with the race detector**

Run: `cd /Users/joannisorlandos/git/wendy/wendyos && go test -race ./go/internal/agent/services/ ./go/internal/cli/commands/`
Expected: PASS (the wendy-update stderr-tail goroutine + stdout scan must be race-clean).

- [ ] **Step 3: Manual smoke (optional, needs a device)**

On a JetPack 7+ device with `wendy-update` installed, run `wendy os update <artifact>` from an interactive terminal and confirm the percent bar advances during `Writing image...` and the labels change through `Verifying...` / `Switching boot slot...`. Confirm a mender-only device still shows `Installing update...` progress.

---

## Self-review notes

- **Spec coverage:** Agent stdout-JSON parsing (Task 1, 3), dual auto-detect backend (Task 2, 3), `ota` capability + neutral gate (Task 4, 6), CLI percent rendering + labels (Task 5, 6), error-tail on failure and malformed-line skipping (Task 1, 3), tests at each layer (Tasks 1, 2, 5, 6, 7). The spec's "download byte percent in wendyos-update" is intentionally dropped — see the Repo & scope note (streaming makes it redundant/harmful).
- **Indeterminate percent handling:** `osUpdateProgressMsg` carries `lastPercent` forward because `tui.ProgressModel` sets percent unconditionally from `ProgressUpdateMsg.Percent`; sending a zero would snap the bar to 0 during verify/swap.
- **Type consistency:** `scanWendyUpdateProgress(io.Reader, func(string,int32), func(string)) error`, `resolveOTABinary() (string, otaBackend, bool)`, `formatOTAFailure(error, []string) string`, `osUpdateProgressMsg(string, int32, float64) (tui.ProgressUpdateMsg, float64)` — names are used identically across tasks.
