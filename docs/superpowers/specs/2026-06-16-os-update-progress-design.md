# End-to-end OS update progress — design

Date: 2026-06-16

## Problem

Running `wendy os update` shows nothing meaningful in the terminal: an
interactive spinner sits on "Downloading update..." for the whole install,
then jumps to done. The end-user gets no sense of progress.

The update chain is **wendyos-update → wendy-agent → CLI**, and it was built
for the legacy *mender* client, not the new *wendy-update* tool that replaces
mender on JetPack 7+:

- **wendyos-update** already emits machine-readable progress as JSON lines on
  **stdout** (`{"phase","percent"}`), per the frozen v1 CLI contract
  (`docs/cli-contract.md`). Phases: `download`, `write`, `verify`, `swap`,
  `done`. This part works.
- **wendy-agent** (`go/internal/agent/services/os_update_service.go`) shells out
  to `mender-update`, reads its **stderr**, scrapes a percentage with the regex
  `(\d{1,3})%`, and forwards a gRPC `Progress{phase, percent}`. It never reads
  stdout, so wendy-update's JSON progress is invisible to it — no `Progress`
  messages flow.
- **CLI** (`go/internal/cli/commands/os_cmd.go`) streams the gRPC responses but
  renders a `SpinnerModel` showing only a phase *label*; the `percent` is
  discarded even when present.

Two compounding breaks: the agent reads the wrong stream with a mender-shaped
parser, and the CLI drops the percentage.

## Goal

The end-user running `wendy os update` sees live progress — a real percentage
bar during download and image write, and a labeled indicator for the quick
verify/swap phases — for devices whose OTA backend is `wendy-update`, without
breaking devices still on `mender-update`.

## Non-goals

- No proto changes. `UpdateOSResponse.Progress` already carries `phase`
  (string) and `percent` (int32, so `-1` = indeterminate is representable).
- No `msg`/human-text passthrough in v1 (YAGNI). `phase` + `percent` give a
  labeled bar, which is the whole ask. Adding a `message` string to the proto
  is a clean additive follow-up if wanted later.
- No streaming of `commit`/`rollback` progress. Those run at boot via the
  systemd units shipped with wendy-update (and the agent's startup commit),
  not through the interactive `UpdateOS` stream, so there is no terminal UI to
  feed.

## The shared contract (wire formats — unchanged)

1. **wendyos-update → agent**: stdout, one JSON object per line:
   `{"phase": string, "percent": int}` where `percent` is `0–100`, or `-1`
   when indeterminate. (Already the frozen v1 contract.)
2. **agent → CLI**: gRPC `UpdateOSResponse.Progress{phase, percent}`.
   No change.
3. **Phase vocabulary** flows through verbatim from wendyos-update to the CLI;
   the CLI owns the human-readable labels.

## Architecture

Three coupled edits across three repos, tied together by the contract above.

### 1. wendyos-update (this repo) — download byte percent

`cmd/wendy-update/main.go` `cmdInstall` currently emits a single
`download:-1` line, then nothing until `write` begins. For a large artifact on
a slow link the user sees a frozen "downloading".

- Wrap the HTTP response body in a counting reader. Using `resp.ContentLength`,
  emit throttled `download` percent (`0–100`), applying the same
  emit-only-on-change throttling the engine already uses for `write`
  (`internal/engine/engine.go:116`).
- When `resp.ContentLength <= 0` (chunked / gzip / unknown), keep emitting a
  single `download:-1`.
- `write` already streams `0→100`; `verify`/`swap` stay `-1` (sub-second).
- No changes to `commit`/`rollback`/`status`.

### 2. wendy-agent — backend abstraction + wendy-update parser

In `go/internal/agent/services/`:

- **`resolveOTABinary()`**: prefer `wendy-update`, fall back to
  `mender-update`. Mirrors `resolveMenderBinary`'s candidate-path probing
  (PATH via `exec.LookPath`, then absolute-path `os.Stat`).
- **Progress reader** — abstract the per-backend output parsing into two
  implementations:
  - *wendy-update*: scan **stdout** line-by-line, `json.Unmarshal` each line
    into `{phase, percent}`, forward as gRPC `Progress`. The stderr pipe still
    feeds the existing `lineRing` so failure text is captured.
  - *mender*: the existing stderr-regex path, unchanged.
- `UpdateOS` selects the binary via `resolveOTABinary`, picks the matching
  reader, and sends `Progress`/`Completed`/`Failed` exactly as today:
  - wendy-update's terminal `done` line → `Completed{reboot_required: true}`.
  - non-zero exit → `Failed` with the captured stderr tail, via the existing
    failure formatter (rename `formatMenderFailure` → backend-neutral, e.g.
    `formatOTAFailure`; keep behavior).
- **Capability advertising** (`detectFeatureset`, `agent_service.go:252`):
  advertise `"ota"` when *either* `wendy-update` or `mender-update` is present;
  keep advertising `"mender"` when mender is present (back-compat). The agent is
  auto-updated before the OS update (`ensureAgentUpToDate`), so CLI/agent
  version skew on the new `"ota"` feature is not a concern.

### 3. CLI — render the percentage

In `go/internal/cli/commands/os_cmd.go`:

- **Gating** (`validateOSUpdateTarget`, line 61): accept the `"ota"` feature
  **or** `"mender"`. Reword `wendyOSMissingMenderMessage` to be
  backend-neutral (no longer "mender-update was not found").
- **Rendering**: replace the install `SpinnerModel` with the existing
  `tui.ProgressModel` (it already renders bar + title + optional byte counter —
  `go/internal/cli/tui/progress.go`). In the stream goroutine, map each
  `Progress`:
  - `percent >= 0` → `ProgressUpdateMsg{Title: phaseLabel(phase),
    Percent: float64(percent)/100}`.
  - `percent == -1` → `ProgressUpdateMsg{Title: phaseLabel(phase)}` only
    (Percent unchanged), so the bar holds while quick phases flash their label.
  - `Completed` → `ProgressDoneMsg{}`; `Failed` → `ProgressDoneMsg{Err: ...}`.
- **Non-TTY** path (`drainOSUpdateStream`) already prints label changes to
  stderr — unchanged.
- **`phaseLabel`** (line 559): add the wendy-update phases — `download →
  "Downloading update..."`, `write → "Writing image..."`, `verify →
  "Verifying..."`, `swap → "Switching boot slot..."` — and keep the existing
  mender cases (`downloading`, `installing`, `finalizing`).

## Error handling

- A malformed JSON line on wendy-update's stdout is logged and skipped; it never
  terminates the stream. wendy-update's stderr remains the source of truth for
  human-readable failure text.
- wendy-update absent **and** mender absent → the existing "no OTA backend"
  `Failed` response, with the neutral message.
- The CLI's existing cancel/EOF/error handling on the gRPC stream is preserved.

## Testing

- **wendyos-update**: unit-test the counting reader — emits monotonic
  `download` percent against a known `ContentLength`, and falls back to a single
  `-1` when length is unknown.
- **wendy-agent**:
  - table-test the stdout-JSON reader: valid lines → `Progress`; a malformed
    line is skipped; `done` → `Completed`; non-zero exit → `Failed` carrying the
    stderr tail.
  - `resolveOTABinary` precedence (wendy-update preferred over mender).
  - `detectFeatureset` advertises `"ota"` when either backend is present.
- **CLI**: `phaseLabel` returns the right strings for the new phases; the
  `Progress`→`ProgressUpdateMsg` mapping sets Percent for `>= 0` and leaves it
  unchanged for `-1`.

## Rollout

Devices on JetPack 7+ ship `wendy-update`; t234/r36 production stays on
`mender-update`. The dual auto-detect backend means both work from the same
agent and CLI build with no per-device configuration. The CLI auto-updates the
agent before each OS update, so the new `"ota"` capability and parser land
before the update proceeds.
