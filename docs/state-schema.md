# On-device state (v1 — frozen)

Everything lives under `/data/wendy-update/` (the persistent `data`
partition, GPT id 17 on Tegra). One JSON state file, transitions are
atomic file replaces (write tmp + rename). No database.

```
/data/wendy-update/
├── state.json        # pending-update record (absent = no update in flight)
├── installed.json    # committed artifact history (small, capped at 10)
├── boot_attempted    # double-boot detector (slot number of last attempt)
└── bl-version-before # transient, capsule updates only
```

## state.json

```json
{
  "schema": 1,
  "phase": "written|swapped|failed",
  "target_slot": 1,
  "artifact_name": "wendyos-image-...-0.16.0",
  "artifact_version": "0.16.0",
  "payload_sha256": "<hex>",
  "bootloader_update": false,
  "created": "2026-06-07T12:00:00Z"
}
```

Ordering rules (power-cut safety):

1. `state.json` (phase=written) is persisted **before** the slot flip.
2. phase=swapped is persisted **after** the flip succeeds, before reporting
   "reboot required".
3. `commit` removes `state.json` and appends to `installed.json` —
   in that order; a crash between the two loses only history, not safety.
4. The verify unit sets phase=failed when the platform flagged the boot;
   a `state.json` with phase=swapped on the OLD slot after reboot means
   UEFI fell back — also failed.

## installed.json

```json
{"history": [{"artifact_name": "...", "artifact_version": "...", "committed": "<ts>", "slot": 1}]}
```
