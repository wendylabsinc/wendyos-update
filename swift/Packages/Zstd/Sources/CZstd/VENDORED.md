# Vendored zstd

`zstd.c` and `include/zstd.h` are the official single-file amalgamation of
[zstd 1.5.6](https://github.com/facebook/zstd/releases/tag/v1.5.6), produced
from the upstream release tarball via:

```
tar xzf zstd-1.5.6.tar.gz
cd zstd-1.5.6/build/single_file_libs
./create_single_file_library.sh   # runs combine.py -> zstd.c
```

then copying `build/single_file_libs/zstd.c` to `zstd.c` here and
`lib/zstd.h` to `include/zstd.h` unmodified.

This is vendored (rather than linked against a system `libzstd`) so the
static-musl (`aarch64-swift-linux-musl`) cross build doesn't need `zstd.h`
or `libzstd.a` in the SDK sysroot — the musl Static Linux SDK ships
`zlib.h` + static `libz` but not zstd. Compiling zstd's C sources directly
into the `CZstd` target means the resulting binary needs no system zstd at
all, static or dynamic.

`LICENSE` here is zstd's own upstream license (BSD-3-Clause, dual-licensed
with GPLv2 at your option — see the file for the full text), copied
unmodified from the same release tarball.

To update to a newer zstd release: repeat the steps above with the new
version's tarball, replace all three files, and re-run
`scripts/dsw test --filter ZstdTests` plus the musl cross build (see
docs/swift-build.md) to confirm nothing regressed.
