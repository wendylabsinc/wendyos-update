# Connector architecture (v1 — frozen)

The portability guarantee of wendyos-update: **supporting a new board
means writing one connector, nothing else.** The engine, artifact format,
state machine, CLI, and systemd units are board-agnostic and never change
per board.

## The boundary

The generic engine owns:

- artifact download/parse/validation (`.wendy`, see manifest-schema.md)
- streaming the payload to a block device with rolling sha256
- the pending-update state machine (`state.json`, see state-schema.md)
- the CLI contract and exit codes
- the verify/auto-commit systemd flow and `health.d/` gates

A connector owns everything the platform decides:

- how the active slot is determined
- which block device a slot maps to
- how a slot is made eligible to boot, flipped to, and marked good
- how the platform signals "the last boot was bad"
- what a platform/bootloader update means and how it's verified

The engine calls the connector ONLY through this interface
(`internal/connector/connector.go`):

| Method | Called when | Tegra (validated) | RPi / U-Boot (mapping) |
|---|---|---|---|
| `CurrentSlot()` | everywhere | `nvbootctrl -t rootfs get-current-slot` | root device from `/proc/cmdline` or `fw_printenv` slot var |
| `PartitionFor(slot)` | before write | partlabel `APP`/`APP_b` → lsblk → nv_boot_control.conf → number toggle | fixed p2/p3 or PARTUUID map (partuuid-rpi class) |
| `PrepareTarget(slot)` | after write, before flip | reset `RootfsStatusSlot*` efivar (also re-seeds retry budget) | clear stale trial state in U-Boot env |
| `SwapSlot(slot, stagePlatformUpdate)` | install (true) + rollback (false) | install: `set-active-boot-slot` OR capsule staging + OsIndications (never both); rollback: pure `set-active-boot-slot`, no rootfs mount | `fw_setenv` target slot + arm trial boot (`bootcount=0`, `upgrade_available=1`); rollback: re-point only |
| `BootIsCompromised()` | verify unit, early boot | any `RootfsStatusSlot*` status ≠ 0 | `upgrade_available=1` but running the OLD slot ⇒ U-Boot fell back |
| `VerifyPlatformUpdate(blUpdate)` | commit, before finalize | BL version + ESRT cascade | no-op in v1 (rpi-eeprom has its own flow) |
| `AbortPlatformUpdate()` | rollback, before swap-back | remove staged capsule from ESP + disarm OsIndications | no-op in v1 |
| `MarkGood()` | commit, after verify | clear bookkeeping + reset inactive slot status var | `upgrade_available=0`, persist slot var |

Design rules that keep the boundary honest:

1. **No connector type leaks into the engine.** The engine imports
   `connector`, never `connector/tegrauefi`. New connectors register
   themselves; the engine resolves by name.
2. **Connectors never touch engine state.** `state.json` is engine-owned;
   connectors keep their own bookkeeping (e.g. `boot_attempted`) under
   `/data/wendyos-update/connector/<name>/` if they need any.
3. **Interface changes are additive.** If a future board needs a hook the
   interface lacks, the hook is added with a no-op default meaning for
   existing connectors — connectors are never rewritten for each other.
4. **Reboots belong to the caller**, never to the engine or a connector.

## Connector selection

Resolution order:

1. `connector` key in `/etc/wendyos-update/config.json` (explicit wins)
2. auto-detect: each registered connector ships a `Detect()` probe
   (tegrauefi: `nvbootctrl` present + the NVIDIA efivar GUID visible;
   ubootenv: `fw_printenv` present + our env layout)
3. no match → hard error (never guess on an OTA path)

The Yocto recipe may also pin the connector per machine via the config
file it installs — build-time choice, runtime override possible.

## What a new board must provide (checklist)

1. A Go package under `internal/connector/<name>/` implementing the
   interface + `Detect()`.
2. A/B rootfs partitions on block storage, and a boot flow where **each
   slot is self-contained bootable** (kernel loaded from the slot's own
   rootfs or per-slot boot partition — the Tegra extlinux and
   meta-mender-raspberrypi U-Boot patterns both qualify).
3. A platform answer to "the new slot failed to boot" (firmware retry like
   Tegra, or a bootloader trial-boot script like U-Boot bootcount).
4. Image/layout integration in meta-edgeos (partitions, `/data`), which is
   Yocto work, not tool work.

## Known scope limits (v1, explicit)

- Block-device A/B only. Raw NAND/UBI boards would need a different write
  path — out of scope until such a board exists.
- One payload per artifact (the rootfs). Boards needing separately
  flashed boot partitions per slot need either the self-contained-slot
  image design (preferred, proven) or a v2 multi-payload format.
- The RPi column above is a paper validation against meta-mender-raspberrypi
  prior art; it becomes real when the ubootenv connector is implemented
  (plan Phase 7). The interface was shaped against it deliberately —
  U-Boot's "arm a trial boot at flip time" is the furthest behavior from
  Tegra's "firmware does everything", and both fit.
