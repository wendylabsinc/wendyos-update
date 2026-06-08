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
| 4 | Platform verification failed at commit (caller should expect rollback) |

## Output streams

- **stdout**: machine-readable only. JSON lines:
  `{"phase":"download|write|verify|flip|commit","percent":0-100,"msg":"..."}`
  `status --json` prints a single JSON object.
- **stderr**: human-readable logs. Never parse stderr.

## Paths

- State: `/data/wendy-update/` (see `state-schema.md`)
- Config: `/etc/wendy-update/config.json` (backend selection override,
  partition map if not autodetected)
- Health hooks: `/etc/wendy-update/health.d/` (executables; non-zero
  exit defers auto-commit)

## systemd units (shipped with the tool)

- `wendy-update-verify.service` — early boot, before the commit unit:
  checks slot-health efivars + double-boot detection; marks a pending
  deployment failed if the platform flagged the boot.
- `wendy-update-commit.service` — oneshot after `multi-user.target`
  (+ health.d gates): runs `wendy-update commit`.
