# wendyos-update CLI contract (v1 — frozen)

This contract is the integration surface for callers (humans, scripts, and
later the wendy-agent wrapper). Changes after v1 are additive only.

## Verbs

| Verb | Does | Reboots? |
|---|---|---|
| `install <url\|path>` | Full install of a `.wendy` artifact up to "reboot required": validate → write inactive slot → set pending state → prepare target slot → flip (or stage capsule) | **No** — caller reboots |
| `commit` | Verify the running slot is the expected one, run platform verification (capsule cascade if applicable), finalize, clear pending state | No |
| `rollback` | Explicit flip-back of an uncommitted update | No |
| `switch <other\|a\|b>` | Make the other slot active for the next boot **without** an update — a permanent re-point (not a trial). Refuses while an update is pending, or when already on the target slot. The target must hold a bootable system. | **No** — caller reboots |
| `status [--json] [--verbose]` | Per-slot state for **both** A/B — rootfs device + health, distro and kernel version, trial retries/notes — plus a system-wide section (bootloader version, last capsule status) and any pending update. `--verbose` adds a raw board `diagnostics` map for debugging (raw `RootfsStatusSlot` bytes, per-slot bootloader state, `BootChainFw*`, `OsIndications`). Inactive-slot distro/kernel are read via a best-effort read-only mount (root only; `unknown` otherwise). Best-effort/display-only. | No |
| `mark-good` | Manual escape hatch: reset slot health vars, clear pending state | No |
| `pack <flags>` | Host-side: build a `.wendy` artifact from a rootfs image (`--image --name --version --device... -o`); self-verifies by re-reading the output unless `--no-verify` | n/a |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Generic error (message on stderr) |
| 2 | `commit`: nothing to commit (NOT an error — mirrors mender-update; wendy-agent already special-cases it) |
| 3 | Artifact rejected (incompatible device, bad checksum, malformed) |
| 4 | Verification failed at commit — platform (firmware slot/ESRT) OR a health.d hook; the deployment is marked failed, caller should expect rollback |

## Output streams

- **stdout**: machine-readable only. JSON lines:
  `{"phase":"download|write|verify|flip|commit","percent":0-100,"msg":"..."}`
  `status --json` prints a single JSON object:
  `{connector, current_slot, slots[], system[], pending, diagnostics}`, where
  each `slots[]` entry is `{slot, booted, partition, distro, kernel,
  rootfs_health, retries, note}` (empty fields omitted) and `system[]` is an
  ordered `{key, value}` list. `slots[]`/`system[]` are additive since v1; the
  `diagnostics` map is still always present (back-compat), and `--verbose` only
  enriches it with the raw EFI/slot snapshot. The human (non-JSON) view shows
  the structured sections by default and the raw `diagnostics` only under
  `--verbose`. The high-frequency progress JSON is suppressed when stdout is a
  TTY (a human gets the stderr bar instead); machine callers always pipe
  stdout, so they still receive it.
- **stderr**: human-readable logs — never parse it. Format adapts to where
  the tool runs (`internal/log`):
  - **interactive terminal**: colored step lines + an in-place progress bar
    (carriage-return updated).
  - **under systemd** (detected via `$JOURNAL_STREAM`): plain lines carrying
    sd-daemon `<N>` severity prefixes (`<3>` err, `<4>` warning, `<6>` info,
    `<7>` debug) that journald parses into PRIORITY. systemd captures the
    service's stderr into the journal automatically — no socket wiring.
  - **piped/redirected**: plain timestamped lines.
  - The progress bar is interactive-only: in non-TTY modes (journal, piped)
    it is omitted entirely — the phase transitions are already logged as
    step lines (`downloading`, write throughput, `verify`…), so per-percent
    updates would just be journal noise.
  - Every line is tagged `wendyos-update:`. `WENDY_DEBUG=1` enables debug
    records (per-hook discovery/env/timing live here); `NO_COLOR` disables
    color.

## Paths

- State: `/data/wendyos-update/` (see `state-schema.md`)
- Config: `/etc/wendyos-update/config.json` (backend selection override,
  partition map if not autodetected)
- Lifecycle hooks: `/etc/wendyos-update/<phase>.d/` — products drop
  executables that run in lexical order at fixed points in the update
  sequence. Empty/absent dir = no hooks. Network-independent by design
  (gate on local app/service readiness, not connectivity). Each hook
  receives update context in its environment: `WENDY_PHASE`,
  `WENDY_ARTIFACT_NAME`, `WENDY_ARTIFACT_VERSION`, `WENDY_TARGET_SLOT`,
  `WENDY_CURRENT_SLOT`, `WENDY_BOOTLOADER_UPDATE`, `WENDY_STATE_DIR`.

  | Dir | Runs | First non-zero exit |
  |---|---|---|
  | `pre-install.d/` | `install`, after the device/version gates, before writing the slot | aborts install (nothing written), exit 1 |
  | `post-install.d/` | `install`, after the slot swap, before "reboot required" | aborts + unwinds the staged update (re-points the active slot back, drops any staged capsule), exit 1 |
  | `health.d/` | `commit`, after the firmware-level platform verify | fails the commit gate: deployment marked failed, exit 4 (a reboot rolls back) |
  | `post-commit.d/` | `commit`, after the update is finalized | advisory — logged, never fatal (too late to undo) |
  | `on-failure.d/` | when a deployment is marked failed (boot-verify fallback, or a commit/health/platform failure) | advisory — logged, never fatal |

  The health phase honours a legacy `health_dir` config override; all
  phases otherwise live under `hooks_dir` (default `/etc/wendyos-update`).

## systemd units (shipped with the tool)

- `wendyos-update-verify.service` — early boot, before the commit unit:
  checks slot-health efivars + double-boot detection; marks a pending
  deployment failed if the platform flagged the boot.
- `wendyos-update-commit.service` — oneshot, ordered after
  `wendyos-update-verify.service` + `data.mount` (NOT `multi-user.target`,
  to stay network-independent); runs `wendyos-update commit`, which applies
  the health.d gate. `Before=wendyos-update-boot-complete.target`.
- `wendyos-update-boot-complete.target` — passive milestone reached once the
  running slot has been committed; downstream units may order after it.

> **Deployment note (manual-commit model).** An image may *mask* these units
> to require an explicit `wendyos-update commit` instead of auto-committing on
> boot (WendyOS does this fleet-wide for the commit unit; the verify unit is
> masked on Jetson until the boot-verify efivar fix is validated there). The
> tool still ships and self-enables them by default — masking is an image
> decision, see meta-edgeos.
