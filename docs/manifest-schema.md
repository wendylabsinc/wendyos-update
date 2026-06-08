# .wendy artifact format (v1 — frozen)

A `.wendy` file is a **tar archive** (no outer compression) with a fixed
member order so the whole artifact installs in one streaming pass from a
URL — no temp copy of the payload.

```
manifest.json        # FIRST member — everything needed to validate up front
manifest.sig         # reserved for future signing; absent in v1
payload              # the rootfs image, compressed per manifest
```

## manifest.json

```json
{
  "format_version": 1,
  "artifact_name": "wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0",
  "artifact_version": "0.16.0",
  "compatible_devices": ["jetson-agx-thor"],
  "payload": {
    "name": "wendyos-image.ext4.zst",
    "size": 0,
    "sha256": "<hex digest of the UNCOMPRESSED image>",
    "compressed_sha256": "<hex digest of the tar member as stored>",
    "compression": "zstd"
  },
  "bootloader_update": false,
  "min_tool_version": "0.1.0"
}
```

Field semantics:

- `compatible_devices` — matched against `/etc/wendyos/device-type`
  (WENDYOS_BOARD_ID). Install refuses (exit 3) on mismatch.
- `payload.sha256` — verified with a rolling hash while streaming the
  decompressed image to the block device; mismatch → exit 3, slot not
  flipped.
- `bootloader_update` — informational/logging only. The source of truth
  for capsule staging is the marker file INSIDE the written rootfs
  (`/var/lib/wendyos/update-bootloader`) plus the capsule at
  `/opt/nvidia/UpdateCapsule/tegra-bl.cap` — the decision belongs to the
  new image, not to whoever packaged the artifact.
- `min_tool_version` — forward-compat gate; older tools refuse artifacts
  they can't handle correctly (exit 3).
