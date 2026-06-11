# wendy-update CLI contract (v1 — frozen)

This contract is the integration surface for callers (humans, scripts, and
later the wendy-agent wrapper). Changes after v1 are additive only.

## Verbs

| Verb | Does | Reboots? |
|---|---|---|
| `install <url\|path>` | Full install of a `.wendy` artifact up to "reboot required": validate → write inactive slot → set pending state → prepare target slot → flip (or stage capsule) | **No** — caller reboots |
| `commit` | Verify the running slot is the expected one, run platform verification (capsule cascade if applicable), finalize, clear pending state | No |
| `rollback` | Explicit flip-back of an uncommitted update | No |
| `status [--json]` | Current slot, partitions, installed artifact name/version, pending state, last error | No |
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
  `status --json` prints a single JSON object. The high-frequency progress
  JSON is suppressed when stdout is a TTY (a human gets the stderr bar
  instead); machine callers always pipe stdout, so they still receive it.
- **stderr**: human-readable logs — never parse it. Format adapts to where
  the tool runs (`internal/log`):
  - **interactive terminal**: colored step lines + an in-place progress bar
    (carriage-return updated).
  - **under systemd** (detected via `$JOURNAL_STREAM`): plain lines carrying
    sd-daemon `<N>` severity prefixes (`<3>` err, `<4>` warning, `<6>` info,
    `<7>` debug) that journald parses into PRIORITY; progress becomes
    discrete throttled lines (no carriage returns). systemd captures the
    service's stderr into the journal automatically — no socket wiring.
  - **piped/redirected**: plain timestamped lines.
  - Every line is tagged `wendy-update:`. `WENDY_DEBUG=1` enables debug
    records; `NO_COLOR` disables color.

## Paths

- State: `/data/wendy-update/` (see `state-schema.md`)
- Config: `/etc/wendy-update/config.json` (backend selection override,
  partition map if not autodetected)
- Health hooks: `/etc/wendy-update/health.d/` — executables run by
  `commit` in lexical order after the firmware-level verify. The first
  non-zero exit fails the gate (commit marks the deployment failed, exit
  4). Empty/absent dir = firmware-level gate only. Network-independent;
  products add hooks here to gate on app/service readiness.

## systemd units (shipped with the tool)

- `wendy-update-verify.service` — early boot, before the commit unit:
  checks slot-health efivars + double-boot detection; marks a pending
  deployment failed if the platform flagged the boot.
- `wendy-update-commit.service` — oneshot, ordered after
  `wendy-update-verify.service` + `data.mount` (NOT `multi-user.target`,
  to stay network-independent); runs `wendy-update commit`, which applies
  the health.d gate. `Before=wendy-update-boot-complete.target`.
- `wendy-update-boot-complete.target` — passive milestone reached once the
  running slot has been committed; downstream units may order after it.
