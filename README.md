# wendy-update

Generic A/B OTA tool for WendyOS. Replaces the Mender client and its Tegra
glue on JetPack 7+ (meta-mender-tegra has no wrynose support). Standalone
by design: CLI + systemd units, no agent dependency — wendy-agent
integrates later by shelling out, exactly as it does with `mender-update`
today.

- Plan: `meta-edgeos/docs/plans/wendy-ota-update.md`
- Platform validation (Phase 1, AGX Thor): `meta-edgeos/docs/docs-ext/wendy-ota-phase1-results.md`
- Mender analysis the design derives from: `meta-edgeos/docs/docs-ext/mender-implementation.md`

## Frozen v1 contracts (docs/)

- `docs/cli-contract.md` — verbs, exit codes, JSON-lines progress
- `docs/manifest-schema.md` — the `.wendy` artifact format
- `docs/state-schema.md` — `/data/wendy-update/` state files
- `docs/connector-architecture.md` — the portability guarantee: a new
  board = one connector, the rest stays generic

## Layout

```
cmd/wendy-update/           CLI entry point
internal/artifact/             .wendy manifest + streaming reader
internal/engine/               update sequencing, state.json
internal/connector/            Connector interface + registry/auto-detect
internal/connector/tegrauefi/  Jetson connector (nvbootctrl + efivars + capsule)
systemd/                       verify + auto-commit units
```

## Build

Cross-compiled by Yocto (`go.bbclass`) via the `wendy-update` recipe in
meta-edgeos. Host build for development: standard `go build ./...`.

## Status

Phase 2 (skeleton + tegra-uefi backend) in progress. The backend is a
direct port of the three hardware-validated meta-edgeos state scripts;
every platform primitive it uses was validated on t264/r38 (2026-06-07)
and t234/r36 (production Mender stack).
